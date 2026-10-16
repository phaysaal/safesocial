import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import 'call_config.dart';
import 'debug_log_service.dart';
import 'secure_store.dart';
import 'inbound_events.dart';
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

  /// Members named in a group call invite, so accepting can announce to them.
  List<String> _pendingGroupMembers = const [];

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
      final devices = sessions.devicesOf(contactKey,
          fallback: _resolveExchangeKey?.call(contactKey));
      if (devices.isEmpty) throw NoSessionException(contactKey);
      for (final device in devices) {
        final mailbox = await sessions.mailboxFor(
          peerIdentityKey: contactKey,
          peerKeyExchangePublicKey: device,
          purpose: 'call',
        );
        await _signaling.connectMailbox(contactKey, mailbox, deviceKey: device);
      }
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
  bool _isSpeakerOn = false;
  bool _isIncomingCall = false;
  RTCSessionDescription? _pendingOffer; // stored until callee accepts
  
  // Getters
  CallState get state => _state;
  CallType get callType => _callType;
  String? get remoteContactName => _remoteContactName;

  /// The other party's identity key in a one-to-one call.
  String? get remoteContactKey => _remoteContactKey;

  /// Looks a contact's name up locally. A caller's own claim about its name
  /// is never shown; the contact list is the only source.
  String? Function(String identityKey)? resolveName;

  /// The name to show for [identityKey], or a short form of the key.
  String nameFor(String identityKey) =>
      resolveName?.call(identityKey) ??
      (identityKey.length > 8 ? '${identityKey.substring(0, 8)}…' : identityKey);
  bool get isMuted => _isMuted;
  bool get isCameraOff => !sendingVideo;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isIncomingCall => _isIncomingCall;
  MediaStream? get localStream => _localStream;
  Map<String, MediaStream> get remoteStreams => _remoteStreams;

  void Function(String contactKey, String contactName, CallType type)? onIncomingCall;

  /// STUN and TURN for a call. By default the relay issues short-lived
  /// credentials for its own coturn; [CallConfig] handles custom servers and
  /// the no-TURN choice. A TURN server sees both parties' IPs and the shape of
  /// the call when a direct path is unavailable, so whose server it is matters.
  Future<List<Map<String, String>>> _iceServersFor(String peerKey) {
    return CallConfig.resolve(() async {
      final sessions = _sessions;
      if (sessions == null) return null;
      try {
        final mailbox = await sessions.mailboxFor(
          peerIdentityKey: peerKey,
          peerKeyExchangePublicKey: _resolveExchangeKey?.call(peerKey),
          purpose: 'call',
        );
        return _signaling.fetchTurnCredentials(mailbox);
      } on NoSessionException {
        return null;
      }
    });
  }

  void setMyInfo(String key, String secretKey) {
    _myPublicKey = key;
    _signaling.onMessageReceived = _handleSignaling;
  }

  void connectSignaling(String contactKey) {
    if (_myPublicKey == null) return;
    DebugLogService().info('Call', 'Connecting signaling channel → $contactKey');
    _connectSignalingMailbox(contactKey);
  }

  // ── Call history ──────────────────────────────────────────────────────────

  static const _logKey = 'spheres_call_log_v1';
  final List<Map<String, dynamic>> _log = [];
  List<Map<String, dynamic>> get callLog => List.unmodifiable(_log);
  DateTime? _connectedAt;

  Future<void> loadLog() async {
    try {
      final raw = await SecureStore.instance.getString(_logKey);
      if (raw != null) {
        _log
          ..clear()
          ..addAll((jsonDecode(raw) as List).cast<Map<String, dynamic>>());
      }
    } catch (_) {}
  }

  Future<void> _record({
    required String peer,
    required bool incoming,
    required bool answered,
    required bool video,
    int seconds = 0,
  }) async {
    _log.insert(0, {
      'id': '$peer:${DateTime.now().millisecondsSinceEpoch}',
      'peer': peer,
      'incoming': incoming,
      'answered': answered,
      'video': video,
      'at': DateTime.now().toIso8601String(),
      'seconds': seconds,
    });
    if (_log.length > 200) _log.removeRange(200, _log.length);
    await SecureStore.instance.setString(_logKey, jsonEncode(_log));
    notifyListeners();
    if (incoming && !answered) {
      InboundEvents.emit(InboundEvent(
        kind: InboundKind.call,
        id: 'missed:$peer:${DateTime.now().millisecondsSinceEpoch}',
        title: nameFor(peer),
        body: 'Missed ${video ? 'video' : 'voice'} call',
        route: '/chat/$peer',
        thread: 'call:$peer',
      ));
    }
  }

  // ── Video in and out of a call ────────────────────────────────────────────
  //
  // A call's kind (audio or video) is only how it rang. Either side may turn
  // its camera on in a voice call or off in a video call at any time. The
  // first time a phone sends video on a connection it adds the track and
  // renegotiates (`call_update`, answered by `call_update_answer`); after
  // that, on and off are a track swap on the same sender plus a `call_video`
  // line so the other side's screen knows. Both sides offering at once is
  // settled by key order: the polite side rolls its offer back, answers, and
  // offers again.

  bool _sharingScreen = false;
  bool get sharingScreen => _sharingScreen;
  MediaStream? _screenStream;
  MediaStreamTrack? _cameraTrack;

  /// The sender that carries our video to each peer, once there is one.
  final Map<String, RTCRtpSender> _videoSenders = {};

  /// Peers we have a renegotiation offer out to.
  final Set<String> _offering = {};

  /// Peers whose offer we rolled back for, and still owe an offer.
  final Set<String> _reoffer = {};

  /// Whether each peer sends video now, as they told us.
  final Map<String, bool> _remoteVideo = {};

  /// Bumped whenever a track joins or leaves a stream the screen already
  /// holds, since the stream object stays the same and a renderer attached
  /// to it would not notice.
  int _mediaRevision = 0;
  int get mediaRevision => _mediaRevision;

  /// Whether this phone sends a picture now: its camera or its screen.
  bool get sendingVideo => _sharingScreen || _cameraTrack != null;

  /// Whether [peer] sends a picture now.
  bool remoteSendsVideo(String peer) => _remoteVideo[peer] ?? false;

  /// Whether anyone in the call sends a picture, so the screen lays out for
  /// video.
  bool get hasVideo => sendingVideo || _remoteVideo.values.any((v) => v);

  // ── Notes ──────────────────────────────────────────────────────────────────
  //
  // Either side may start notes; the other side is told with a `call_notes`
  // line and starts its own, so both phones note their own voice and each
  // screen says who began it. Nothing of what is said travels here.

  bool _notesOn = false;
  String? _notesBy;

  /// Whether notes are on in this call, on both phones.
  bool get notesOn => _notesOn;

  /// 'me', or the identity key of the peer who started them.
  String? get notesStartedBy => _notesBy;

  /// Turn notes on or off for everyone in the call.
  Future<void> setNotes(bool on) async {
    if (_state != CallState.connected && _state != CallState.connecting) return;
    if (_notesOn == on) return;
    _notesOn = on;
    _notesBy = on ? 'me' : null;
    notifyListeners();
    final targets = <String>{..._peerConnections.keys, if (_remoteContactKey != null) _remoteContactKey!};
    for (final peer in targets) {
      await _sendSignal(peer, {'type': 'call_notes', 'on': on});
    }
  }

  /// The other side turned notes on or off. Public so the rule is testable
  /// without a socket.
  @visibleForTesting
  void applyNotesSignal(String sender, Map<String, dynamic> data) {
    final on = data['on'] == true;
    if (_notesOn == on) return;
    _notesOn = on;
    _notesBy = on ? sender : null;
    DebugLogService().info('Call', 'Notes turned ${on ? 'on' : 'off'} by ${sender.substring(0, 8)}…');
    notifyListeners();
  }

  /// In a collision, the side with the smaller key gives way. Pure.
  @visibleForTesting
  static bool isPolite(String myKey, String peerKey) => myKey.compareTo(peerKey) < 0;

  /// What a signal says about the sender's video, falling back to the call's
  /// kind for an older client that does not say. Pure.
  @visibleForTesting
  static bool remoteVideoFrom(Map<String, dynamic> data, {required bool fallback}) {
    final v = data['video'];
    return v is bool ? v : fallback;
  }

  /// Turn our camera on or off in the call we are in. On needs the camera
  /// permission and throws when it is refused, so the screen can say so.
  Future<void> setVideo(bool on) async {
    if (_state == CallState.idle || _state == CallState.ended) return;
    if (on == (_cameraTrack != null)) return;
    if (on) {
      final status = await Permission.camera.request();
      if (!status.isGranted) throw StateError('Camera permission refused');
      final cam = await navigator.mediaDevices
          .getUserMedia({'audio': false, 'video': {'facingMode': 'user'}});
      final track = cam.getVideoTracks().first;
      final stream = _localStream;
      if (stream == null) {
        track.stop();
        return;
      }
      await stream.addTrack(track);
      _cameraTrack = track;
      DebugLogService().info('Call', 'Camera on');
      if (!_sharingScreen) await _publishVideo(track);
    } else {
      final track = _cameraTrack;
      _cameraTrack = null;
      DebugLogService().info('Call', 'Camera off');
      if (!_sharingScreen) await _publishVideo(null);
      if (track != null) {
        track.stop();
        await _localStream?.removeTrack(track);
      }
    }
    _mediaRevision++;
    notifyListeners();
  }

  /// The screen's camera button.
  Future<void> toggleCamera() => setVideo(_cameraTrack == null);

  /// Replace the camera with the screen on every peer connection, or back.
  /// Android needs a foreground service for capture; if the platform refuses,
  /// the call carries on with the camera and the error is reported.
  Future<void> toggleScreenShare() async {
    if (_sharingScreen) {
      _screenStream?.getTracks().forEach((t) => t.stop());
      _screenStream = null;
      _sharingScreen = false;
      await _publishVideo(_cameraTrack);
      _mediaRevision++;
      notifyListeners();
      return;
    }
    final screen = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
    final track = screen.getVideoTracks().first;
    _screenStream = screen;
    _sharingScreen = true;
    await _publishVideo(track);
    _mediaRevision++;
    notifyListeners();
  }

  /// Put [track] (or nothing) on the video sender of every peer. A peer that
  /// has no video sender yet gets one and a renegotiation; the rest get a
  /// swap and a `call_video` line.
  Future<void> _publishVideo(MediaStreamTrack? track) async {
    final stream = _localStream;
    for (final entry in _peerConnections.entries.toList()) {
      final peer = entry.key, pc = entry.value;
      final sender = _videoSenders[peer];
      if (sender != null) {
        await sender.replaceTrack(track);
        unawaited(_sendSignal(peer, {'type': 'call_video', 'on': track != null}));
      } else if (track != null && stream != null) {
        _videoSenders[peer] = await pc.addTrack(track, stream);
        await _renegotiate(peer);
      }
    }
  }

  Future<void> _renegotiate(String peer) async {
    final pc = _peerConnections[peer];
    if (pc == null) return;
    _offering.add(peer);
    _reoffer.remove(peer);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    DebugLogService().info('Call', 'Renegotiating with ${peer.substring(0, 8)}… (video ${sendingVideo ? 'on' : 'off'})');
    await _sendSignal(peer, {
      'type': 'call_update',
      'sdp': offer.sdp,
      'sdp_type': offer.type,
      'video': sendingVideo,
    });
  }

  /// Fired when a group call starts, so the sphere chat can carry a "join"
  /// line. Set by the app.
  Future<void> Function(String groupId, List<String> members, CallType type)? onGroupCallStarted;

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
      _remoteVideo[contactKey] = type == CallType.video;
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
    unawaited(onGroupCallStarted?.call(groupId, members, type));
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
        'members': members,
      });
    }
  }

  /// Join an existing Group Call.
  Future<void> joinGroupCall(String groupId, List<String> members, CallType type) async {
    if (_state != CallState.idle && _state != CallState.ringing) return;
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
    if (_remoteContactKey == null) {
      DebugLogService().warn('Call', 'acceptCall ignored — no remote key');
      return;
    }

    // A group invite carries no SDP offer — the joiner announces itself and
    // the existing participants offer to it. Accepting one previously fell
    // through the pendingOffer guard and did nothing at all.
    if (_pendingOffer == null) {
      final groupId = _groupId;
      if (groupId == null) {
        DebugLogService()
            .warn('Call', 'acceptCall ignored — no pending offer and no group');
        return;
      }
      final members = _pendingGroupMembers.isNotEmpty
          ? _pendingGroupMembers
          : [_remoteContactKey!];
      _pendingGroupMembers = const [];
      _isIncomingCall = false;
      await joinGroupCall(groupId, members, _callType);
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
      'video': sendingVideo,
    });
  }

  Future<void> endCall() async {
    DebugLogService().info('Call', 'endCall — closing ${_peerConnections.length} peer connection(s)');
    final remoteForLog = _remoteContactKey;
    if (remoteForLog != null && _groupId == null) {
      final answered = _connectedAt != null || _state == CallState.connected;
      await _record(
        peer: remoteForLog,
        incoming: _isIncomingCall,
        answered: answered || !_isIncomingCall,
        video: _callType == CallType.video,
        seconds: _connectedAt == null ? 0 : DateTime.now().difference(_connectedAt!).inSeconds,
      );
    }
    _connectedAt = null;
    if (_sharingScreen) await toggleScreenShare();
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
    _videoSenders.clear();
    _offering.clear();
    _reoffer.clear();
    _remoteVideo.clear();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    _cameraTrack = null;
    _notesOn = false;
    _notesBy = null;
    _pendingCandidates.clear();
    _pendingGroupMembers = const [];
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
    _cameraTrack = _localStream!.getVideoTracks().firstOrNull;
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

    final iceServers = await _iceServersFor(peerKey);
    final pcConfig = CallConfig.peerConnectionConfig(iceServers);
    DebugLogService().info('Call',
        'ICE: ${iceServers.length} server(s), TURN ${iceServers.any((s) => s['urls']!.startsWith('turn')) ? 'available' : 'absent'}'
        '${pcConfig.containsKey('iceTransportPolicy') ? ', relay only' : ''}');
    final pc = await createPeerConnection(pcConfig);
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
      final sender = await pc.addTrack(track, _localStream!);
      if (track.kind == 'video') _videoSenders[peerKey] = sender;
    }

    pc.onTrack = (event) {
      DebugLogService().info('Call', 'Remote ${event.track.kind} track received from $peerKey — streams: ${event.streams.length}');
      if (event.streams.isNotEmpty) {
        _remoteStreams[peerKey] = event.streams[0];
        _mediaRevision++;
        notifyListeners();
      }
    };

    pc.onIceCandidate = (candidate) {
      // Type only: the full line carries this phone's addresses.
      final kind = RegExp(r'typ (\w+)').firstMatch(candidate.candidate ?? '')?.group(1) ?? '?';
      DebugLogService().info('Call', 'ICE candidate ($kind) → ${peerKey.substring(0, 8)}…');
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
        'video': sendingVideo,
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
  /// The device on the other end of the current 1:1 call, once known.
  ///
  /// An offer rings every device the contact has; whichever answers first is
  /// the call, and everything after the offer goes to that device alone. On
  /// the callee side it is the device the offer came from.
  String? _remoteDeviceKey;

  static const _ringsAllDevices = {'call_offer', 'group_call_invite', 'group_call_join'};

  /// How old a ring may be and still ring. Longer than any relay hop, shorter
  /// than the gap between a missed call and the next app start.
  static const Duration ringWindow = Duration(seconds: 45);

  /// Whether a ring is too old to act on. A ring with no stamp (an older
  /// client) is treated as current.
  @visibleForTesting
  static bool isStaleRing(Map<String, dynamic> data, {DateTime? now}) {
    final at = data['at'];
    if (at is! num) return false;
    final sent = DateTime.fromMillisecondsSinceEpoch(at.toInt());
    return (now ?? DateTime.now()).difference(sent) > ringWindow;
  }

  Future<void> _sendSignal(String contactKey, Map<String, dynamic> data) async {
    final sessions = _sessions;
    if (sessions == null) {
      DebugLogService().warn('Call', 'No crypto context; cannot signal');
      return;
    }

    try {
      final type = data['type'];
      if (type == 'call_offer') _remoteDeviceKey = null;
      final onlyDevice = (!_ringsAllDevices.contains(type) &&
              contactKey == _remoteContactKey)
          ? _remoteDeviceKey
          : null;
      final sealed = await sessions.sealForDevices(
        peerIdentityKey: contactKey,
        fallbackExchangeKey: _resolveExchangeKey?.call(contactKey),
        type: 'call',
        // Stamped so a receiver can tell a ring from a replay.
        plaintext: jsonEncode({...data, 'at': DateTime.now().millisecondsSinceEpoch}),
        mode: SealMode.wrap,
        onlyDevice: onlyDevice,
      );
      await _signaling.sendSealed(contactKey, sealed);
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
      if (_ringsAllDevices.contains(type) && isStaleRing(data)) {
        // Signalling is never acknowledged by the live path, so the mailbox
        // hands an old offer back on the next restart. Nobody is calling.
        DebugLogService().info('Call', 'Ignoring a $type from the past');
        return;
      }
      DebugLogService().info('Call', 'handleSignaling: received [$type] from $senderKey — currentState=$_state');

      switch (type) {
        case 'call_offer':
          if (_state == CallState.idle) {
            _remoteContactKey = senderKey;
            _remoteDeviceKey = opened.fromDevice;
            _remoteContactName = nameFor(senderKey);
            _callType = data['call_type'] == 'video' ? CallType.video : CallType.audio;
            _remoteVideo[senderKey] =
                remoteVideoFrom(data, fallback: _callType == CallType.video);
            _pendingOffer = RTCSessionDescription(data['sdp'], data['sdp_type']);
            _isIncomingCall = true;
            _state = CallState.ringing;
            DebugLogService().info('Call', 'Incoming ${_callType.name} call from $_remoteContactName — stored pending offer, firing onIncomingCall');
            InboundEvents.emit(InboundEvent(
              kind: InboundKind.call,
              id: 'call:$senderKey:${DateTime.now().millisecondsSinceEpoch ~/ 30000}',
              title: _remoteContactName!,
              body: 'Incoming ${_callType == CallType.video ? 'video' : 'voice'} call',
              route: '/call',
              thread: 'call:$senderKey',
            ));
            onIncomingCall?.call(senderKey, _remoteContactName!, _callType);
          } else {
            DebugLogService().info('Call', 'call_offer received while busy ($state) — auto-answering as mesh peer');
            _remoteVideo[senderKey] =
                remoteVideoFrom(data, fallback: data['call_type'] == 'video');
            await _setupPeer(senderKey, isInitiator: false);
            await _peerConnections[senderKey]!.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
            await _flushPendingCandidates(senderKey);
            final answer = await _peerConnections[senderKey]!.createAnswer();
            await _peerConnections[senderKey]!.setLocalDescription(answer);
            _sendSignal(senderKey, {'type': 'call_answer', 'sdp': answer.sdp, 'sdp_type': answer.type, 'video': sendingVideo});
          }
          break;
        case 'call_answer':
          if (senderKey == _remoteContactKey && _groupId == null) {
            if (_remoteDeviceKey == null) {
              // First device to pick up gets the call.
              _remoteDeviceKey = opened.fromDevice;
            } else if (_remoteDeviceKey != opened.fromDevice) {
              // Another of their devices answered too late; let it go.
              DebugLogService().info('Call', 'A second device answered; declining it');
              final sealed = await sessions.sealForDevices(
                peerIdentityKey: senderKey,
                fallbackExchangeKey: _resolveExchangeKey?.call(senderKey),
                type: 'call',
                plaintext: jsonEncode({'type': 'call_end'}),
                mode: SealMode.wrap,
                onlyDevice: opened.fromDevice,
              );
              await _signaling.sendSealed(senderKey, sealed);
              break;
            }
          }
          DebugLogService().info('Call', 'call_answer received from $senderKey — setting remote description');
          _remoteVideo[senderKey] =
              remoteVideoFrom(data, fallback: _callType == CallType.video);
          await _peerConnections[senderKey]?.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
          await _flushPendingCandidates(senderKey);
          _state = CallState.connected;
          _connectedAt ??= DateTime.now();
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
            _remoteContactName = nameFor(senderKey);
            // The invite says whether it is audio or video. This was ignored,
            // so a video call was joined as audio.
            _callType =
                data['call_type'] == 'video' ? CallType.video : CallType.audio;
            _remoteVideo[senderKey] = _callType == CallType.video;
            _pendingGroupMembers = (data['members'] as List<dynamic>? ?? [])
                .whereType<String>()
                .toList();
            _isIncomingCall = true;
            _state = CallState.ringing;
            onIncomingCall?.call(senderKey, 'Group Call', _callType);
          }
          break;
        case 'group_call_join':
          DebugLogService().info('Call', 'group_call_join from $senderKey — groupMatch=${_groupId == data['group_id']}');
          if (_state == CallState.connected || _groupId == data['group_id']) {
            await _setupPeer(senderKey, isInitiator: true);
          }
          break;
        case 'call_update':
        case 'call_update_answer':
        case 'call_video':
          await _handleVideoSignal(type as String, senderKey, opened.fromDevice, data);
          break;
        case 'call_notes':
          if (_peerConnections.containsKey(senderKey) || senderKey == _remoteContactKey) {
            applyNotesSignal(senderKey, data);
          }
          break;
        case 'call_end':
          if (senderKey == _remoteContactKey &&
              _remoteDeviceKey != null &&
              _remoteDeviceKey != opened.fromDevice &&
              _groupId == null) {
            // One of their other devices stopped ringing; the call itself is
            // with a different device.
            break;
          }
          DebugLogService().info('Call', 'call_end from $senderKey — closing connection');
          if (_state == CallState.ringing && _isIncomingCall && senderKey == _remoteContactKey) {
            await _record(
                peer: senderKey, incoming: true, answered: false,
                video: _callType == CallType.video);
            _remoteContactKey = null;
            _pendingOffer = null;
            _isIncomingCall = false;
          }
          await _peerConnections[senderKey]?.close();
          _peerConnections.remove(senderKey);
          _remoteStreams.remove(senderKey);
          _videoSenders.remove(senderKey);
          _offering.remove(senderKey);
          _reoffer.remove(senderKey);
          _remoteVideo.remove(senderKey);
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

  /// A mid-call change of picture from [senderKey]. In a one-to-one call
  /// only the device we are talking to is heard; another of their devices
  /// has nothing to say about this call.
  Future<void> _handleVideoSignal(
      String type, String senderKey, String? fromDevice, Map<String, dynamic> data) async {
    if (_groupId == null &&
        senderKey == _remoteContactKey &&
        _remoteDeviceKey != null &&
        fromDevice != _remoteDeviceKey) {
      return;
    }
    final pc = _peerConnections[senderKey];
    if (pc == null) return;
    switch (type) {
      case 'call_video':
        _remoteVideo[senderKey] = data['on'] == true;
        _mediaRevision++;
        DebugLogService().info('Call', '${senderKey.substring(0, 8)}… turned video ${data['on'] == true ? 'on' : 'off'}');
        break;
      case 'call_update':
        if (_offering.contains(senderKey)) {
          final me = _myPublicKey ?? '';
          if (!isPolite(me, senderKey)) {
            DebugLogService().info('Call', 'Offers crossed; ours stands, theirs is dropped');
            return;
          }
          DebugLogService().info('Call', 'Offers crossed; giving way and offering again after');
          try {
            await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
          } catch (e) {
            DebugLogService().warn('Call', 'Rollback refused: $e');
            return;
          }
          _offering.remove(senderKey);
          _reoffer.add(senderKey);
        }
        _remoteVideo[senderKey] = remoteVideoFrom(data, fallback: _remoteVideo[senderKey] ?? false);
        await pc.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        await _sendSignal(senderKey, {
          'type': 'call_update_answer',
          'sdp': answer.sdp,
          'sdp_type': answer.type,
          'video': sendingVideo,
        });
        _mediaRevision++;
        if (_reoffer.contains(senderKey)) await _renegotiate(senderKey);
        break;
      case 'call_update_answer':
        if (!_offering.remove(senderKey)) {
          DebugLogService().warn('Call', 'An update answer with no offer out; ignored');
          return;
        }
        _remoteVideo[senderKey] = remoteVideoFrom(data, fallback: _remoteVideo[senderKey] ?? false);
        await pc.setRemoteDescription(RTCSessionDescription(data['sdp'], data['sdp_type']));
        _mediaRevision++;
        break;
    }
  }

  Future<void> switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track != null) await Helper.switchCamera(track);
  }
}
