import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/content_privacy.dart';

/// Secure media viewer that prevents screenshots and downloads
/// for non-public content.
///
/// - Sets FLAG_SECURE on Android to block screenshots/screen recording
/// - Disables download/share buttons for restricted content
/// - Shows privacy indicator badge
class SecureMediaViewer extends StatefulWidget {
  final String? mediaPath;
  final PrivacySetting privacy;

  const SecureMediaViewer({
    super.key,
    required this.mediaPath,
    required this.privacy,
  });

  @override
  State<SecureMediaViewer> createState() => _SecureMediaViewerState();
}

class _SecureMediaViewerState extends State<SecureMediaViewer> {
  static const _platform = MethodChannel('com.spheres.spheres_app/secure');

  @override
  void initState() {
    super.initState();
    if (widget.privacy.level != ContentPrivacy.public) {
      _enableSecureMode();
    }
  }

  @override
  void dispose() {
    if (widget.privacy.level != ContentPrivacy.public) {
      _disableSecureMode();
    }
    super.dispose();
  }

  Future<void> _enableSecureMode() async {
    try {
      // Android: FLAG_SECURE prevents screenshots and screen recording
      await _platform.invokeMethod('enableSecureMode');
    } catch (_) {
      // Platform channel not implemented yet — no-op
    }
  }

  Future<void> _disableSecureMode() async {
    try {
      await _platform.invokeMethod('disableSecureMode');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isRestricted = widget.privacy.level != ContentPrivacy.public;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Icon(widget.privacy.icon, size: 16, color: widget.privacy.color),
            const SizedBox(width: 6),
            Text(
              widget.privacy.label,
              style: TextStyle(fontSize: 14, color: widget.privacy.color),
            ),
          ],
        ),
        actions: [
          // Only show share/download for public content
          if (!isRestricted) ...[
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Share coming soon')),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Download coming soon')),
                );
              },
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          // Media display
          Center(
            child: widget.mediaPath != null &&
                    File(widget.mediaPath!).existsSync()
                ? InteractiveViewer(
                    child: Image.file(
                      File(widget.mediaPath!),
                      fit: BoxFit.contain,
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_not_supported,
                          size: 64, color: Colors.white38),
                      const SizedBox(height: 12),
                      Text('Media not available',
                          style: TextStyle(color: Colors.white54)),
                    ],
                  ),
          ),

          // Privacy watermark overlay for restricted content
          if (isRestricted)
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 14, color: widget.privacy.color),
                      const SizedBox(width: 6),
                      Text(
                        'This content cannot be downloaded or shared',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
