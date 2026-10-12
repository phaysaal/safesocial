import 'package:flutter/material.dart';

import '../models/media_protection.dart';

/// What a protected send needs from the sender: where the picture comes from
/// and whether the viewer's name goes across it.
class ProtectedChoice {
  final String source; // 'camera', 'photo' or 'video'
  final MediaProtection protection;
  const ProtectedChoice(this.source, this.protection);
}

/// The sheet behind "Protected photo or video" in a chat. It says plainly
/// what protection does and does not do before anything is picked.
Future<ProtectedChoice?> showProtectedMediaSheet(BuildContext context) {
  var watermark = false;
  return showModalBottomSheet<ProtectedChoice>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('Protected photo or video'),
                subtitle: Text(MediaProtection.disclaimer),
              ),
              SwitchListTile(
                value: watermark,
                onChanged: (v) => setSheet(() => watermark = v),
                title: const Text("Write the viewer's name across it"),
                subtitle: const Text('A photo of the screen then says who was looking'),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(
                    ctx, ProtectedChoice('camera', MediaProtection(watermark: watermark))),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photo'),
                onTap: () => Navigator.pop(
                    ctx, ProtectedChoice('photo', MediaProtection(watermark: watermark))),
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('Video'),
                onTap: () => Navigator.pop(
                    ctx, ProtectedChoice('video', MediaProtection(watermark: watermark))),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
