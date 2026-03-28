import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../../services/call_service.dart';
import '../../widgets/avatar.dart';

/// Full-screen call UI — audio or video.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callService = context.watch<CallService>();
    final isVideo = callService.callType == CallType.video;

    // Update renderers
    _localRenderer.srcObject = callService.localStream;
    _remoteRenderer.srcObject = callService.remoteStream;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // ── Background / remote video ─────────────────────
            if (isVideo && callService.state == CallState.connected)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              // Audio call or connecting — show avatar
              Positioned.fill(
                child: _buildAudioBackground(callService),
              ),

            // ── Local video (small, top-right) ────────────────
            if (isVideo && callService.localStream != null)
              Positioned(
                top: 20,
                right: 20,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 120,
                    height: 160,
                    child: RTCVideoView(
                      _localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ),

            // ── Call info (top) ───────────────────────────────
            Positioned(
              top: 40,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(
                    callService.remoteContactName ?? 'Unknown',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _stateText(callService.state),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),

            // ── Incoming call buttons ─────────────────────────
            if (callService.isIncomingCall &&
                callService.state == CallState.ringing)
              Positioned(
                bottom: 60,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: 'Decline',
                      onTap: () => callService.rejectCall(),
                    ),
                    _CallButton(
                      icon: Icons.call,
                      color: Colors.green,
                      label: 'Accept',
                      size: 72,
                      onTap: () => callService.acceptCall(),
                    ),
                  ],
                ),
              ),

            // ── In-call controls ──────────────────────────────
            if (callService.state == CallState.connected ||
                (callService.state == CallState.ringing &&
                    !callService.isIncomingCall) ||
                callService.state == CallState.connecting)
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _CallButton(
                          icon: callService.isMuted
                              ? Icons.mic_off
                              : Icons.mic,
                          color: callService.isMuted
                              ? Colors.red
                              : Colors.white24,
                          label: 'Mute',
                          onTap: () => callService.toggleMute(),
                        ),
                        if (isVideo)
                          _CallButton(
                            icon: callService.isCameraOff
                                ? Icons.videocam_off
                                : Icons.videocam,
                            color: callService.isCameraOff
                                ? Colors.red
                                : Colors.white24,
                            label: 'Camera',
                            onTap: () => callService.toggleCamera(),
                          ),
                        _CallButton(
                          icon: callService.isSpeakerOn
                              ? Icons.volume_up
                              : Icons.volume_down,
                          color: callService.isSpeakerOn
                              ? Colors.blue
                              : Colors.white24,
                          label: 'Speaker',
                          onTap: () => callService.toggleSpeaker(),
                        ),
                        if (isVideo)
                          _CallButton(
                            icon: Icons.cameraswitch,
                            color: Colors.white24,
                            label: 'Flip',
                            onTap: () => callService.switchCamera(),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _CallButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: 'End',
                      size: 64,
                      onTap: () {
                        callService.endCall();
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioBackground(CallService callService) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(
              displayName: callService.remoteContactName ?? '?',
              size: AvatarSize.large,
            ),
            const SizedBox(height: 24),
            if (callService.state == CallState.ringing &&
                callService.isIncomingCall)
              Text(
                'Incoming ${callService.callType.name} call...',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 16,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _stateText(CallState state) => switch (state) {
        CallState.idle => '',
        CallState.ringing => 'Ringing...',
        CallState.connecting => 'Connecting...',
        CallState.connected => 'Connected',
        CallState.ended => 'Call ended',
      };
}

/// Circular call control button.
class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final double size;
  final VoidCallback onTap;

  const _CallButton({
    required this.icon,
    required this.color,
    required this.label,
    this.size = 56,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: size * 0.45),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}
