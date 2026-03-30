import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import 'crypto_service.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
import 'rust_core_service.dart';

/// Call state.
enum CallState { idle, ringing, connecting, connected, ended }

/// Call type.
enum CallType { audio, video }

/// Manages WebRTC audio/video calls using a Full Mesh P2P architecture.
class CallService extends ChangeNotifier {
  final RelayService _signaling = RelayService();
  final RustCoreService _rustCore = RustCoreService();
  String? _myPublicKey;
  String? _mySecretKey;

  // WebRTC Mesh: Map of PeerPublicKey -> Connection/Stream
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  MediaStream? _localStream;

  // State
  CallState _state = CallState.idle;
  CallType _callType = CallType.audio;
  String? _groupId; // Current group context
  String? _remoteContactKey; // For 1:1 calls
  String? _remoteContactName;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isSpeakerOn = false;
  bool _isIncomingCall = false;
  RTCSessionDescription? _pendingOffer; // stored until callee accepts
  
  // Getters
  CallState get state => _state;
  CallType get callType => _callType;
  String? get remoteContactName => _remoteContactName;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isIncomingCall => _isIncomingCall;
  MediaStream? get localStream => _localStream;
  Map<String, MediaStream> get remoteStreams => _remoteStreams;

  void Function(String contactKey, String contactName, CallType type)? onIncomingCall;

  static const _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {
      'urls': 'turn:openrelay.metered.ca:80',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
    {
      'urls': 'turn:openrelay.metered.ca:443',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
    {
      'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ];

  void setMyInfo(String key, String secretKey) {
    _myPublicKey = key;
    _mySecretKey = secretKey;
    _signaling.onMessageReceived = _handleSignaling;
  }

  void connectSignaling(String contactKey) {
    if (_myPublicKey == null) return;
    _signaling.connect('call:$_myPublicKey', 'call:$contactKey', mySecretKey: _mySecretKey, authPublicKey: _myPublicKey);
  }

  /// Start a 1:1 call.
  Future<void> startCall(String contactKey, String contactName, CallType type) async {
    if (_state != CallState.idle) return;
    _remoteContactKey = contactKey;
    _remoteContactName = contactName;
    _callType = type;
    _isIncomingCall = false;
    _state = CallState.connecting;
    notifyListeners();

    try {
      await _requestPermissions(type);
      await _initLocalStream(type);
      await _setupPeer(contactKey, isInitiator: true);
      _state = CallState.ringing;
      notifyListeners();
    } catch (e) {
      await endCall();
    }
  }

  /// Start a Group Call.
  Future<void> startGroupCall(String groupId, List<String> members, CallType type) async {
    if (_state != CallState.idle) return;
    _groupId = groupId;
    _callType = type;
    _state = CallState.connected;
    notifyListeners();

    await _requestPermissions(type);
    await _initLocalStream(type);

    // Invite all members via group relay
    for (final memberKey in members) {
      if (memberKey == _myPublicKey) continue;
      _sendSignal(memberKey, {
        'type': 'group_call_invite',
        'group_id': groupId,
        'call_type': type.name,
        'caller_name': 'Group Call',
      });
    }
  }

  /// Join an existing Group Call.
  Future<void> joinGroupCall(String groupId, List<String> members, CallType type) async {
    if (_state != CallState.idle) return;
    _groupId = groupId;
    _callType = type;
    _state = CallState.connected;
    notifyListeners();

    await _requestPermissions(type);
    await _initLocalStream(type);

    // Announce arrival to everyone in the group
    for (final memberKey in members) {
      if (memberKey == _myPublicKey) continue;
      _sendSignal(memberKey, {
        'type': 'group_call_join',
        'group_id': groupId,
      });
    }
  }

  Future<void> acceptCall() async {
    if (_remoteContactKey == null || _pendingOffer == null) return;
    _state = CallState.connecting;
    notifyListeners();

    await _requestPermissions(_callType);
    await _initLocalStream(_callType);
    await _setupPeer(_remoteContactKey!, isInitiator: false);

    final pc = _peerConnections[_remoteContactKey!]!;
    await pc.setRemoteDescription(_pendingOffer!);
    _pendingOffer = null;

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _sendSignal(_remoteContactKey!, {
      'type': 'call_answer',
      'sdp': answer.sdp,
      'sdp_type': answer.type,
    });
  }

  Future<void> endCall() async {
    final targets = _peerConnections.keys.toList();
    for (var key in targets) {
      _sendSignal(key, {'type': 'call_end'});
      await _peerConnections[key]?.close();
    }
    _peerConnections.clear();
    _remoteStreams.clear();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    _state = CallState.idle;
    _groupId = null;
    _pendingOffer = null;
    _isIncomingCall = false;
    notifyListeners();
  }

  // ── Private methods ────────────────────────────────────────────────────────

  Future<void> _requestPermissions(CallType type) async {
    if (type == CallType.video) {
      await [Permission.camera, Permission.microphone].request();
    } else {
      await Permission.microphone.request();
    }
  }

  Future<void> _initLocalStream(CallType type) async {
    if (_localStream != null) return;
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': type == CallType.video ? {'facingMode': 'user'} : false,
    });
  }

  Future<void> _setupPeer(String peerKey, {required bool isInitiator}) async {
    if (_peerConnections.containsKey(peerKey)) return;

    final pc = await createPeerConnection({'iceServers': _iceServers, 'sdpSemantics': 'unified-plan'});
    _peerConnections[peerKey] = pc;

    _localStream?.getTracks().forEach((track) {
      pc.addTrack(track, _localStream!);
    });

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStreams[peerKey] = event.streams[0];
        notifyListeners();
      }
    };

    pc.onIceCandidate = (candidate) {
      _sendSignal(peerKey, {
        'type': 'ice_candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    if (isInitiator) {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _sendSignal(peerKey, {
        'type': 'call_offer',
        'call_type': _callType.name,
        'caller_name': _myPublicKey ?? 'Unknown',
        'sdp': offer.sdp,
        'sdp_type': offer.type,
      });
    }
  }

  void _sendSignal(String contactKey, Map<String, dynamic> data) {
    final plaintext = jsonEncode(data);
    final sharedKey = CryptoService.deriveSharedKey(_myPublicKey ?? '', contactKey);
    _signaling.sendViaRelay('call:$contactKey', CryptoService.encrypt(plaintext, sharedKey));
  }

  void _handleSignaling(String contactKey, String rawData) async {
    final senderKey = contactKey.replaceFirst('call:', '');
    final sharedKey = CryptoService.deriveSharedKey(_myPublicKey ?? '', senderKey);
    
    try {
      final decrypted = CryptoService.decrypt(rawData, sharedKey);
      final data = jsonDecode(decrypted) as Map<String, dynamic>;
      final type = data['type'];

      switch (type) {
        case 'call_offer':
          if (_state == CallState.idle) {
            _remoteContactKey = senderKey;
            _remoteContactName = data['caller_name'];
            _callType = data['call_type'] == 'video' ? CallType.video : CallType.audio;
            _pendingOffer = RTCSessionDescription(data['sdp'], data['sdp_type']);
            _isIncomingCall = true;
            _state = CallState.ringing;
            onIncomingCall?.call(senderKey, _remoteContactName!, _callType);
          } else {
            // Already in a call (group or other)
            await _setupPeer(senderKey, isInitiator: false);
            await _peerConnections[senderKey]!.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
            final answer = await _peerConnections[senderKey]!.createAnswer();
            await _peerConnections[senderKey]!.setLocalDescription(answer);
            _sendSignal(senderKey, {'type': 'call_answer', 'sdp': answer.sdp, 'sdp_type': answer.type});
          }
          break;
        case 'call_answer':
          await _peerConnections[senderKey]?.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
          _state = CallState.connected;
          break;
        case 'ice_candidate':
          await _peerConnections[senderKey]?.addCandidate(RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']));
          break;
        case 'group_call_invite':
          if (_state == CallState.idle) {
            _groupId = data['group_id'];
            _remoteContactKey = senderKey;
            _remoteContactName = data['caller_name'];
            _isIncomingCall = true;
            _state = CallState.ringing;
            onIncomingCall?.call(senderKey, 'Group Call', _callType);
          }
          break;
        case 'group_call_join':
          if (_state == CallState.connected || _groupId == data['group_id']) {
            // New person joined the mesh, send them an offer
            await _setupPeer(senderKey, isInitiator: true);
          }
          break;
        case 'call_end':
          await _peerConnections[senderKey]?.close();
          _peerConnections.remove(senderKey);
          _remoteStreams.remove(senderKey);
          if (_peerConnections.isEmpty) _state = CallState.idle;
          notifyListeners();
          break;
      }
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Call', 'Mesh signaling error: $e');
    }
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !_isMuted);
    notifyListeners();
  }

  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !_isCameraOff);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track != null) await Helper.switchCamera(track);
  }
}
