import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../../services/call_service.dart';
import '../../widgets/avatar.dart';
import 'renderer_gate.dart';

/// Full-screen call UI — supports 1:1 and Group calls via a Mesh grid.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  /// Renderers are created asynchronously by the platform; every stream goes
  /// through a gate so nothing is assigned before its renderer exists.
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  late final RendererGate<MediaStream> _local =
      RendererGate(RtcVideoSink(_localRenderer));
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<String, RendererGate<MediaStream>> _remote = {};

  bool _listenerAdded = false;
  bool _gone = false;
  CallService? _callService;

  @override
  void initState() {
    super.initState();
    _local.onReady = _rebuildIfAlive;
    _local.start();
  }

  /// A renderer may finish initialising after this screen has been popped,
  /// which happens when a call ends within a second of arriving. Rebuilding
  /// a disposed State is an assertion failure, so every late callback goes
  /// through here.
  void _rebuildIfAlive() {
    if (_gone || !mounted) return;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_listenerAdded) {
      final cs = context.read<CallService>();
      _callService = cs;
      cs.addListener(_onCallServiceChanged);
      _listenerAdded = true;
      // The call may already be ringing with streams in place (the receiving
      // side), so take the current state now rather than waiting for a change.
      _local.attach(cs.localStream);
      _syncRemoteRenderers(cs.remoteStreams);
    }
  }

  @override
  void dispose() {
    _gone = true;
    // Looked up once in didChangeDependencies: the context must not be used
    // here, and the gates must be released whatever else happens.
    _callService?.removeListener(_onCallServiceChanged);
    _local.dispose();
    for (final gate in _remote.values) {
      gate.dispose();
    }
    super.dispose();
  }

  void _onCallServiceChanged() {
    if (_gone || !mounted) return;
    final cs = _callService ?? context.read<CallService>();

    // Auto-dismiss when call ends
    if (cs.state == CallState.idle) {
      Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == '/');
      return;
    }

    _local.attach(cs.localStream);
    _syncRemoteRenderers(cs.remoteStreams);
  }

  /// One renderer per remote stream, created once and only shown when ready.
  void _syncRemoteRenderers(Map<String, MediaStream> streams) {
    for (final entry in streams.entries) {
      final existing = _remote[entry.key];
      if (existing != null) {
        existing.attach(entry.value);
        continue;
      }
      final renderer = RTCVideoRenderer();
      final gate = RendererGate<MediaStream>(RtcVideoSink(renderer))
        ..onReady = _rebuildIfAlive;
      _remoteRenderers[entry.key] = renderer;
      _remote[entry.key] = gate;
      gate.attach(entry.value);
      gate.start();
    }
    final toRemove = _remote.keys.where((k) => !streams.containsKey(k)).toList();
    for (final key in toRemove) {
      _remote.remove(key)?.dispose();
      _remoteRenderers.remove(key);
    }
    _rebuildIfAlive();
  }

  /// Remote renderers that can draw right now.
  List<RTCVideoRenderer> get _readyRemoteRenderers => [
        for (final entry in _remote.entries)
          if (entry.value.isReady) _remoteRenderers[entry.key]!,
      ];

  @override
  Widget build(BuildContext context) {
    final callService = context.watch<CallService>();
    final isVideo = callService.callType == CallType.video;
    final remoteReady = _readyRemoteRenderers;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // ── Video Grid (Remotes) ──────────────────────────
            if (isVideo && remoteReady.isNotEmpty)
              _buildVideoGrid(remoteReady)
            else
              // Audio call or connecting — show avatars
              _buildAudioBackground(callService),

            // ── Local video (small, floating) ────────────────
            if (isVideo && _local.isReady && callService.localStream != null)
              Positioned(
                top: 20,
                right: 20,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 100,
                    height: 140,
                    child: RTCVideoView(
                      _localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ),

            // ── Controls ────────────────────────────────────
            _buildControls(context, callService),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoGrid(List<RTCVideoRenderer> renderers) {
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: renderers.length > 2 ? 2 : 1,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: renderers.length,
      itemBuilder: (ctx, i) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: RTCVideoView(
          renderers[i],
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ),
    );
  }

  Widget _buildAudioBackground(CallService callService) {
    return Center(
      child: Wrap(
        spacing: 20,
        runSpacing: 20,
        alignment: WrapAlignment.center,
        children: [
          if (callService.remoteStreams.length <= 1)
            UserAvatar(
                displayName: callService.remoteContactName ?? '?',
                identityKey: callService.remoteContactKey,
                size: AvatarSize.large)
          else
            ...callService.remoteStreams.keys.map((k) => UserAvatar(
                displayName: callService.nameFor(k), identityKey: k, size: AvatarSize.large)),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context, CallService callService) {
    final isRingingIncoming =
        callService.state == CallState.ringing && callService.isIncomingCall;

    return Positioned(
      bottom: 40,
      left: 0,
      right: 0,
      child: Column(
        children: [
          if (isRingingIncoming)
            // Incoming call: Accept / Decline
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CallActionButton(
                  icon: Icons.call_end,
                  onTap: () {
                    callService.endCall();
                    Navigator.pop(context);
                  },
                  color: Colors.red,
                ),
                _CallActionButton(
                  icon: Icons.call,
                  onTap: () => callService.acceptCall(),
                  color: Colors.green,
                ),
              ],
            )
          else
            // Active or outgoing call controls
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CallActionButton(
                  icon: callService.isMuted ? Icons.mic_off : Icons.mic,
                  onTap: () => callService.toggleMute(),
                  active: !callService.isMuted,
                ),
                if (callService.callType == CallType.video) ...[
                  _CallActionButton(
                    icon: callService.isCameraOff ? Icons.videocam_off : Icons.videocam,
                    onTap: () => callService.toggleCamera(),
                    active: !callService.isCameraOff,
                  ),
                  _CallActionButton(
                    icon: callService.sharingScreen ? Icons.stop_screen_share : Icons.screen_share,
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await callService.toggleScreenShare();
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(
                            content: Text('Screen sharing is not available here: $e')));
                      }
                    },
                    active: !callService.sharingScreen,
                  ),
                ],
                _CallActionButton(
                  icon: Icons.call_end,
                  onTap: () {
                    callService.endCall();
                    Navigator.pop(context);
                  },
                  color: Colors.red,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final bool active;

  const _CallActionButton({
    required this.icon,
    required this.onTap,
    this.color,
    this.active = true,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      iconSize: 32,
      style: IconButton.styleFrom(
        backgroundColor: color ?? (active ? Colors.white24 : Colors.red),
        padding: const EdgeInsets.all(16),
      ),
      icon: Icon(icon, color: Colors.white),
    );
  }
}
