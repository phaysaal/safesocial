import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// Call state.
enum CallState { idle, ringing, connecting, connected, ended }

/// Call type.
enum CallType { audio, video }

/// Manages WebRTC audio/video calls using a Full Mesh P2P architecture.
class CallService extends ChangeNotifier {
  final RelayService _signaling = RelayService();
  String? _myPublicKey;
  SessionManager? _sessions;
  String? Function(String identityKey)? _resolveExchangeKey;

  /// ICE candidates that arrived before we had a peer connection for them.
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};
  static const int _maxPendingCandidates = 64;

  /// Supply the crypto context so signalling channels get pairwise addresses.
  void attachCrypto(
    SessionManager sessions,
    String? Function(String identityKey) resolveExchangeKey,
  ) {
    _sessions = sessions;
    _resolveExchangeKey = resolveExchangeKey;
  }

  Future<void> _connectSignalingMailbox(String contactKey) async {
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final mailbox = await sessions.mailboxFor(
        peerIdentityKey: contactKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(contactKey),
        purpose: 'call',
      );
      await _signaling.connectMailbox(contactKey, mailbox);
    } on NoSessionException {
      // Calls need the same pairwise secret as messages; without it there is
      // no address to listen on.
    }
  }

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
    _signaling.onMessageReceived = _handleSignaling;
  }

  void connectSignaling(String contactKey) {
    if (_myPublicKey == null) return;
    DebugLogService().info('Call', 'Connecting signaling channel → $contactKey');
    _connectSignalingMailbox(contactKey);
  }

  /// Start a 1:1 call.
  Future<void> startCall(String contactKey, String contactName, CallType type) async {
    if (_state != CallState.idle) {
      DebugLogService().warn('Call', 'startCall ignored — already in state $_state');
      return;
    }
    DebugLogService().info('Call', 'Starting ${type.name} call → $contactName');
    _remoteContactKey = contactKey;
    _remoteContactName = contactName;
    _callType = type;
    _isIncomingCall = false;
    _state = CallState.connecting;
    notifyListeners();

    try {
      await _requestPermissions(type);
      DebugLogService().info('Call', 'Permissions granted');
      await _initLocalStream(type);
      DebugLogService().info('Call', 'Local stream ready — tracks: ${_localStream?.getTracks().length}');
      await _setupPeer(contactKey, isInitiator: true);
      _state = CallState.ringing;
      DebugLogService().info('Call', 'Offer sent — waiting for answer');
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Call', 'startCall failed: $e');
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
    if (_remoteContactKey == null || _pendingOffer == null) {
      DebugLogService().warn('Call', 'acceptCall ignored — remoteKey=$_remoteContactKey pendingOffer=$_pendingOffer');
      return;
    }
    DebugLogService().info('Call', 'Accepting call from $_remoteContactName ($_remoteContactKey)');
    _state = CallState.connecting;
    notifyListeners();

    await _requestPermissions(_callType);
    await _initLocalStream(_callType);
    await _setupPeer(_remoteContactKey!, isInitiator: false);

    final pc = _peerConnections[_remoteContactKey!]!;
    DebugLogService().info('Call', 'Setting remote description (offer)');
    await pc.setRemoteDescription(_pendingOffer!);
    _pendingOffer = null;
    await _flushPendingCandidates(_remoteContactKey!);

    DebugLogService().info('Call', 'Creating answer');
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    DebugLogService().info('Call', 'Answer sent → $_remoteContactKey');
    _sendSignal(_remoteContactKey!, {
      'type': 'call_answer',
      'sdp': answer.sdp,
      'sdp_type': answer.type,
    });
  }

  Future<void> endCall() async {
    DebugLogService().info('Call', 'endCall — closing ${_peerConnections.length} peer connection(s)');
    // Include the remote party even when no peer connection exists. Declining
    // a ringing call created none, so no call_end was ever sent and the
    // caller's phone rang until they gave up.
    final targets = <String>{..._peerConnections.keys};
    final remote = _remoteContactKey;
    if (remote != null) targets.add(remote);
    for (var key in targets) {
      DebugLogService().info('Call', 'Sending call_end → $key');
      await _sendSignal(key, {'type': 'call_end'});
      await _peerConnections[key]?.close();
    }
    _peerConnections.clear();
    _remoteStreams.clear();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    _pendingCandidates.clear();
    _state = CallState.idle;
    _groupId = null;
    _pendingOffer = null;
    _isIncomingCall = false;
    _remoteContactKey = null;
    _remoteContactName = null;
    DebugLogService().info('Call', 'Call ended — state reset to idle');
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
    if (_localStream != null) {
      DebugLogService().info('Call', 'Local stream already initialized — skipping');
      return;
    }
    DebugLogService().info('Call', 'Requesting ${type.name} media stream');
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': type == CallType.video ? {'facingMode': 'user'} : false,
    });
    final tracks = _localStream!.getTracks();
    DebugLogService().info('Call', 'Local stream ready — ${tracks.length} track(s): ${tracks.map((t) => '${t.kind}(${t.id})').join(', ')}');
  }

  /// Apply any candidates that arrived before this peer connection existed.
  Future<void> _flushPendingCandidates(String peerKey) async {
    final pending = _pendingCandidates.remove(peerKey);
    final pc = _peerConnections[peerKey];
    if (pending == null || pc == null) return;
    for (final candidate in pending) {
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        DebugLogService().warn('Call', 'Could not apply buffered candidate: $e');
      }
    }
    DebugLogService()
        .info('Call', 'Applied ${pending.length} buffered ICE candidate(s)');
  }

  Future<void> _setupPeer(String peerKey, {required bool isInitiator}) async {
    if (_peerConnections.containsKey(peerKey)) {
      DebugLogService().warn('Call', '_setupPeer: already have connection for $peerKey');
      return;
    }
    DebugLogService().info('Call', '_setupPeer: creating PeerConnection for $peerKey (initiator=$isInitiator)');

    final pc = await createPeerConnection({'iceServers': _iceServers, 'sdpSemantics': 'unified-plan'});
    _peerConnections[peerKey] = pc;

    pc.onConnectionState = (state) {
      DebugLogService().info('Call', 'PeerConnection[$peerKey] connectionState → $state');
    };
    pc.onIceConnectionState = (state) {
      DebugLogService().info('Call', 'PeerConnection[$peerKey] iceConnectionState → $state');
    };
    pc.onIceGatheringState = (state) {
      DebugLogService().info('Call', 'PeerConnection[$peerKey] iceGatheringState → $state');
    };
    pc.onSignalingState = (state) {
      DebugLogService().info('Call', 'PeerConnection[$peerKey] signalingState → $state');
    };

    final localTracks = _localStream?.getTracks() ?? [];
    DebugLogService().info('Call', 'Adding ${localTracks.length} local track(s) to peer');
    for (final track in localTracks) {
      pc.addTrack(track, _localStream!);
    }

    pc.onTrack = (event) {
      DebugLogService().info('Call', 'Remote track received from $peerKey — streams: ${event.streams.length}');
      if (event.streams.isNotEmpty) {
        _remoteStreams[peerKey] = event.streams[0];
        notifyListeners();
      }
    };

    pc.onIceCandidate = (candidate) {
      DebugLogService().info('Call', 'ICE candidate → $peerKey: ${candidate.candidate?.substring(0, candidate.candidate!.length > 60 ? 60 : candidate.candidate!.length)}...');
      _sendSignal(peerKey, {
        'type': 'ice_candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    if (isInitiator) {
      DebugLogService().info('Call', 'Creating offer for $peerKey');
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      DebugLogService().info('Call', 'Offer created — sending call_offer to $peerKey');
      _sendSignal(peerKey, {
        'type': 'call_offer',
        'call_type': _callType.name,
        'caller_name': _myPublicKey ?? 'Unknown',
        'sdp': offer.sdp,
        'sdp_type': offer.type,
      });
    }
  }

  /// Seal and send one signalling message.
  ///
  /// Signalling carries SDP and ICE candidates, which contain local and public
  /// IP addresses — so this needs real encryption as much as message content
  /// does. It previously used the placeholder XOR cipher with a key derived
  /// from the two public keys, meaning the relay could read every candidate.
  ///
  /// Sealed with [SealMode.wrap] rather than the ratchet: signalling is bursty,
  /// lossy and order-independent, so a chain both peers must advance in
  /// lockstep is the wrong fit. Replay is still covered by envelope-id dedup.
  Future<void> _sendSignal(String contactKey, Map<String, dynamic> data) async {
    final sessions = _sessions;
    if (sessions == null) {
      DebugLogService().warn('Call', 'No crypto context; cannot signal');
      return;
    }

    try {
      final sealed = await sessions.seal(
        peerIdentityKey: contactKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(contactKey),
        type: 'call',
        plaintext: jsonEncode(data),
        mode: SealMode.wrap,
      );
      await _signaling.sendViaRelay(contactKey, sealed);
    } on NoSessionException {
      DebugLogService().warn(
          'Call', 'No encryption key for $contactKey — cannot signal securely');
    } catch (e) {
      DebugLogService().error('Call', 'Could not send signal: $e');
    }
  }

  void _handleSignaling(String channelKey, String rawData) async {
    final sessions = _sessions;
    if (sessions == null) return;

    try {
      final opened = await sessions.open(
        raw: rawData,
        resolveExchangeKey: (key) => _resolveExchangeKey?.call(key),
      );

      if (opened.type != 'call') {
        DebugLogService()
            .warn('Call', 'Ignoring envelope of type "${opened.type}"');
        return;
      }

      // The peer is whoever signed the envelope, not whichever channel it
      // arrived on — so nobody can inject signalling as someone else.
      final senderKey = opened.from;
      final data = jsonDecode(opened.plaintext) as Map<String, dynamic>;
      final type = data['type'];
      DebugLogService().info('Call', 'handleSignaling: received [$type] from $senderKey — currentState=$_state');

      switch (type) {
        case 'call_offer':
          if (_state == CallState.idle) {
            _remoteContactKey = senderKey;
            _remoteContactName = data['caller_name'];
            _callType = data['call_type'] == 'video' ? CallType.video : CallType.audio;
            _pendingOffer = RTCSessionDescription(data['sdp'], data['sdp_type']);
            _isIncomingCall = true;
            _state = CallState.ringing;
            DebugLogService().info('Call', 'Incoming ${_callType.name} call from $_remoteContactName — stored pending offer, firing onIncomingCall');
            onIncomingCall?.call(senderKey, _remoteContactName!, _callType);
          } else {
            DebugLogService().info('Call', 'call_offer received while busy ($state) — auto-answering as mesh peer');
            await _setupPeer(senderKey, isInitiator: false);
            await _peerConnections[senderKey]!.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
            await _flushPendingCandidates(senderKey);
            final answer = await _peerConnections[senderKey]!.createAnswer();
            await _peerConnections[senderKey]!.setLocalDescription(answer);
            _sendSignal(senderKey, {'type': 'call_answer', 'sdp': answer.sdp, 'sdp_type': answer.type});
          }
          break;
        case 'call_answer':
          DebugLogService().info('Call', 'call_answer received from $senderKey — setting remote description');
          await _peerConnections[senderKey]?.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
          await _flushPendingCandidates(senderKey);
          _state = CallState.connected;
          DebugLogService().success('Call', 'Call connected with $senderKey');
          break;
        case 'ice_candidate':
          final candidate = RTCIceCandidate(
              data['candidate'], data['sdpMid'], data['sdpMLineIndex']);
          final pc = _peerConnections[senderKey];
          if (pc != null) {
            await pc.addCandidate(candidate);
          } else {
            // On the callee side no peer connection exists until the call is
            // accepted, so trickled candidates arriving while ringing used to
            // be dropped and ICE could never complete. Hold them instead.
            final pending = _pendingCandidates.putIfAbsent(senderKey, () => []);
            if (pending.length < _maxPendingCandidates) pending.add(candidate);
            DebugLogService().info('Call',
                'Buffered ICE candidate from $senderKey (${pending.length} held)');
          }
          break;
        case 'group_call_invite':
          if (_state == CallState.idle) {
            _groupId = data['group_id'];
            _remoteContactKey = senderKey;
            _remoteContactName = data['caller_name'];
            _isIncomingCall = true;
            _state = CallState.ringing;
            DebugLogService().info('Call', 'Group call invite from $senderKey — group: ${data['group_id']}');
            onIncomingCall?.call(senderKey, 'Group Call', _callType);
          }
          break;
        case 'group_call_join':
          DebugLogService().info('Call', 'group_call_join from $senderKey — groupMatch=${_groupId == data['group_id']}');
          if (_state == CallState.connected || _groupId == data['group_id']) {
            await _setupPeer(senderKey, isInitiator: true);
          }
          break;
        case 'call_end':
          DebugLogService().info('Call', 'call_end from $senderKey — closing connection');
          await _peerConnections[senderKey]?.close();
          _peerConnections.remove(senderKey);
          _remoteStreams.remove(senderKey);
          if (_peerConnections.isEmpty) {
            _state = CallState.idle;
            DebugLogService().info('Call', 'All peers disconnected — state → idle');
          }
          notifyListeners();
          break;
        default:
          DebugLogService().warn('Call', 'Unknown signaling message type: $type');
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
