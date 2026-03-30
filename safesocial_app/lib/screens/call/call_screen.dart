import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../../services/call_service.dart';
import '../../widgets/avatar.dart';

/// Full-screen call UI — supports 1:1 and Group calls via a Mesh grid.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
  }

  @override
  void dispose() {
    context.read<CallService>().removeListener(_onCallStateChanged);
    _localRenderer.dispose();
    for (var r in _remoteRenderers.values) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _updateRemoteRenderers(Map<String, MediaStream> streams) async {
    // Add new renderers
    for (var entry in streams.entries) {
      if (!_remoteRenderers.containsKey(entry.key)) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = entry.value;
        setState(() {
          _remoteRenderers[entry.key] = renderer;
        });
      }
    }
    // Remove old renderers
    _remoteRenderers.removeWhere((key, renderer) {
      if (!streams.containsKey(key)) {
        renderer.dispose();
        return true;
      }
      return false;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.read<CallService>().addListener(_onCallStateChanged);
  }

  void _onCallStateChanged() {
    final cs = context.read<CallService>();
    if (cs.state == CallState.idle && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == '/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final callService = context.watch<CallService>();
    final isVideo = callService.callType == CallType.video;

    _localRenderer.srcObject = callService.localStream;
    _updateRemoteRenderers(callService.remoteStreams);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // ── Video Grid (Remotes) ──────────────────────────
            if (isVideo && _remoteRenderers.isNotEmpty)
              _buildVideoGrid()
            else
              // Audio call or connecting — show avatars
              _buildAudioBackground(callService),

            // ── Local video (small, floating) ────────────────
            if (isVideo && callService.localStream != null)
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

  Widget _buildVideoGrid() {
    final renderers = _remoteRenderers.values.toList();
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
          if (callService.remoteStreams.isEmpty)
            UserAvatar(displayName: callService.remoteContactName ?? '?', size: AvatarSize.large)
          else
            ..._remoteRenderers.keys.map((k) => UserAvatar(displayName: k, size: AvatarSize.large)),
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
                if (callService.callType == CallType.video)
                  _CallActionButton(
                    icon: callService.isCameraOff ? Icons.videocam_off : Icons.videocam,
                    onTap: () => callService.toggleCamera(),
                    active: !callService.isCameraOff,
                  ),
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
