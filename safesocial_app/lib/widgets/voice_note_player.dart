import 'package:flutter/material.dart';
import 'package:audio_waveforms/audio_waveforms.dart';

import '../crypto/blob.dart';
import '../services/media_service.dart';

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
  String? _error;

  @override
  void initState() {
    super.initState();
    _playerController = PlayerController();
    _preparePlayer();
  }

  Future<void> _preparePlayer() async {
    try {
      // A note that arrived while offline is still a blob reference; fetch it.
      var path = widget.audioPath;
      if (BlobRef.tryDecode(path) != null) {
        final fetched = await MediaService.decodeAndSaveImage(path);
        if (fetched == null) {
          if (mounted) setState(() => _error = 'Could not fetch this voice note');
          return;
        }
        path = fetched;
      }
      await _playerController.preparePlayer(
        path: path,
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
      // Said on the bubble, not only in the log: a disabled play button that
      // never explains itself is a stub reporting success.
      if (mounted) setState(() => _error = 'Cannot play this voice note');
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
          if (_error != null)
            SizedBox(
              width: 150,
              child: Text(_error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: color.withValues(alpha: 0.9))),
            )
          else if (!_isPrepared)
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
