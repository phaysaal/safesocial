import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'debug_log_service.dart';
import 'relay_service.dart';

/// Call state.
enum CallState { idle, ringing, connecting, connected, ended }

/// Call type.
enum CallType { audio, video }

/// Manages WebRTC audio/video calls using the relay for signaling.
class CallService extends ChangeNotifier {
  final RelayService _signaling = RelayService();
  String? _myPublicKey;

  // WebRTC
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // State
  CallState _state = CallState.idle;
  CallType _callType = CallType.audio;
  String? _remoteContactKey;
  String? _remoteContactName;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isSpeakerOn = false;
  bool _isIncomingCall = false;
  String? _pendingOffer;

  // Getters
  CallState get state => _state;
  CallType get callType => _callType;
  String? get remoteContactKey => _remoteContactKey;
  String? get remoteContactName => _remoteContactName;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isIncomingCall => _isIncomingCall;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  /// Callback when an incoming call arrives.
  void Function(String contactKey, String contactName, CallType type)? onIncomingCall;

  // STUN servers for NAT traversal (free, public)
  static const _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun2.l.google.com:19302'},
  ];

  void setMyPublicKey(String key) {
    _myPublicKey = key;
    _signaling.onMessageReceived = _handleSignaling;
  }

  /// Connect signaling channel for a contact.
  void connectSignaling(String contactKey) {
    if (_myPublicKey == null) return;
    _signaling.connect(
      'call:$_myPublicKey',
      'call:$contactKey',
    );
  }

  /// Start an outgoing call.
  Future<void> startCall(String contactKey, String contactName, CallType type) async {
    if (_state != CallState.idle) return;

    _remoteContactKey = contactKey;
    _remoteContactName = contactName;
    _callType = type;
    _isIncomingCall = false;
    _state = CallState.connecting;
    notifyListeners();

    DebugLogService().info('Call', 'Starting ${type.name} call to $contactName');

    try {
      await _initWebRTC(type);

      // Create offer
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      // Send offer via relay
      _sendSignal(contactKey, {
        'type': 'call_offer',
        'call_type': type.name,
        'caller_name': _myPublicKey ?? 'Unknown',
        'sdp': offer.sdp,
        'sdp_type': offer.type,
      });

      _state = CallState.ringing;
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Call', 'Failed to start call: $e');
      await endCall();
    }
  }

  /// Accept an incoming call.
  Future<void> acceptCall() async {
    if (_state != CallState.ringing || _pendingOffer == null) return;

    _state = CallState.connecting;
    notifyListeners();

    try {
      await _initWebRTC(_callType);

      // Set remote offer
      final offerData = jsonDecode(_pendingOffer!) as Map<String, dynamic>;
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(offerData['sdp'], offerData['sdp_type']),
      );

      // Create answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      // Send answer via relay
      _sendSignal(_remoteContactKey!, {
        'type': 'call_answer',
        'sdp': answer.sdp,
        'sdp_type': answer.type,
      });

      _pendingOffer = null;
    } catch (e) {
      DebugLogService().error('Call', 'Failed to accept call: $e');
      await endCall();
    }
  }

  /// Reject an incoming call.
  Future<void> rejectCall() async {
    if (_remoteContactKey != null) {
      _sendSignal(_remoteContactKey!, {'type': 'call_reject'});
    }
    await endCall();
  }

  /// End the current call.
  Future<void> endCall() async {
    if (_remoteContactKey != null) {
      _sendSignal(_remoteContactKey!, {'type': 'call_end'});
    }

    _localStream?.getTracks().forEach((t) => t.stop());
    _remoteStream?.getTracks().forEach((t) => t.stop());
    await _peerConnection?.close();

    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _remoteContactKey = null;
    _remoteContactName = null;
    _pendingOffer = null;
    _isMuted = false;
    _isCameraOff = false;
    _isSpeakerOn = false;
    _state = CallState.idle;
    notifyListeners();

    DebugLogService().info('Call', 'Call ended');
  }

  /// Toggle microphone mute.
  void toggleMute() {
    _isMuted = !_isMuted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !_isMuted);
    notifyListeners();
  }

  /// Toggle camera on/off.
  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !_isCameraOff);
    notifyListeners();
  }

  /// Toggle speaker.
  void toggleSpeaker() {
    _isSpeakerOn = !_isSpeakerOn;
    // Platform-specific speaker control would go here
    notifyListeners();
  }

  /// Switch front/back camera.
  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
  }

  // ── Private methods ────────────────────────────────────────────────────────

  Future<void> _initWebRTC(CallType type) async {
    final config = {
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(config);

    // Get local media
    final mediaConstraints = {
      'audio': true,
      'video': type == CallType.video
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    };
    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);

    // Add tracks to peer connection
    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    // Handle remote stream
    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        _state = CallState.connected;
        DebugLogService().success('Call', 'Call connected');
        notifyListeners();
      }
    };

    // Handle ICE candidates
    _peerConnection!.onIceCandidate = (candidate) {
      if (_remoteContactKey != null) {
        _sendSignal(_remoteContactKey!, {
          'type': 'ice_candidate',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    _peerConnection!.onConnectionState = (state) {
      DebugLogService().info('Call', 'Connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        endCall();
      }
    };
  }

  void _sendSignal(String contactKey, Map<String, dynamic> data) {
    _signaling.sendViaRelay(
      'call:$contactKey',
      jsonEncode(data),
    );
  }

  void _handleSignaling(String contactKey, String rawData) {
    try {
      final data = jsonDecode(rawData) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case 'call_offer':
          _handleCallOffer(contactKey, data);
        case 'call_answer':
          _handleCallAnswer(data);
        case 'call_reject':
          DebugLogService().info('Call', 'Call rejected');
          endCall();
        case 'call_end':
          DebugLogService().info('Call', 'Remote ended call');
          endCall();
        case 'ice_candidate':
          _handleIceCandidate(data);
      }
    } catch (e) {
      DebugLogService().error('Call', 'Signaling error: $e');
    }
  }

  void _handleCallOffer(String contactKey, Map<String, dynamic> data) {
    if (_state != CallState.idle) {
      // Already in a call — send busy
      _sendSignal(contactKey.replaceFirst('call:', ''), {'type': 'call_reject'});
      return;
    }

    final callerName = data['caller_name'] as String? ?? 'Unknown';
    final callTypeStr = data['call_type'] as String? ?? 'audio';
    _callType = callTypeStr == 'video' ? CallType.video : CallType.audio;
    _remoteContactKey = contactKey.replaceFirst('call:', '');
    _remoteContactName = callerName;
    _isIncomingCall = true;
    _pendingOffer = jsonEncode(data);
    _state = CallState.ringing;
    notifyListeners();

    DebugLogService().info('Call', 'Incoming ${_callType.name} call from $callerName');
    onIncomingCall?.call(_remoteContactKey!, callerName, _callType);
  }

  Future<void> _handleCallAnswer(Map<String, dynamic> data) async {
    try {
      await _peerConnection?.setRemoteDescription(
        RTCSessionDescription(data['sdp'], data['sdp_type']),
      );
      DebugLogService().info('Call', 'Answer received, connecting...');
    } catch (e) {
      DebugLogService().error('Call', 'Failed to set answer: $e');
    }
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    try {
      await _peerConnection?.addCandidate(
        RTCIceCandidate(
          data['candidate'],
          data['sdpMid'],
          data['sdpMLineIndex'],
        ),
      );
    } catch (e) {
      DebugLogService().error('Call', 'Failed to add ICE candidate: $e');
    }
  }

  @override
  void dispose() {
    endCall();
    _signaling.disconnectAll();
    super.dispose();
  }
}
