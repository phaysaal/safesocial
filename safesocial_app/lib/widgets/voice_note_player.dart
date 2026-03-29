import 'package:flutter/material.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'dart:io';

/// A modern voice note player with waveform visualization.
class VoiceNotePlayer extends StatefulWidget {
  final String audioPath;
  final bool isMine;

  const VoiceNotePlayer({
    super.key,
    required this.audioPath,
    required this.isMine,
  });

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  late PlayerController _playerController;
  bool _isPrepared = false;

  @override
  void initState() {
    super.initState();
    _playerController = PlayerController();
    _preparePlayer();
  }

  Future<void> _preparePlayer() async {
    try {
      await _playerController.preparePlayer(
        path: widget.audioPath,
        shouldExtractWaveform: true,
        noOfSamples: 100,
        volume: 1.0,
      );
      if (mounted) {
        setState(() {
          _isPrepared = true;
        });
      }
    } catch (e) {
      debugPrint('[VoiceNote] Failed to prepare player: $e');
    }
  }

  @override
  void dispose() {
    _playerController.dispose();
    super.dispose();
  }

  void _togglePlay() async {
    if (_playerController.playerState.isPlaying) {
      await _playerController.pausePlayer();
    } else {
      await _playerController.startPlayer();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.isMine ? Colors.white : theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              _playerController.playerState.isPlaying ? Icons.pause : Icons.play_arrow,
              color: color,
            ),
            onPressed: _isPrepared ? _togglePlay : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 4),
          if (!_isPrepared)
            SizedBox(
              width: 150,
              height: 30,
              child: LinearProgressIndicator(
                backgroundColor: color.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(color.withValues(alpha: 0.3)),
              ),
            )
          else
            AudioFileWaveforms(
              size: const Size(150, 30),
              playerController: _playerController,
              enableSeekGesture: true,
              waveformType: WaveformType.fitWidth,
              playerWaveStyle: PlayerWaveStyle(
                fixedWaveColor: color.withValues(alpha: 0.3),
                liveWaveColor: color,
                spacing: 3,
                waveThickness: 2.5,
              ),
            ),
        ],
      ),
    );
  }
}
