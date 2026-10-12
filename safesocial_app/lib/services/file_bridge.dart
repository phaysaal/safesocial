import 'dart:io';

import 'package:flutter/services.dart';

/// A file the user picked from the device, copied into our cache.
class PickedFile {
  final String path;
  final String name;
  final String mime;
  final int size;
  const PickedFile({required this.path, required this.name, required this.mime, required this.size});
}

/// The device's document picker and viewer, through a small platform
/// channel. Built for Android; elsewhere it says so rather than pretending.
class FileBridge {
  FileBridge._();

  static const _channel = MethodChannel('spheres/files');

  /// Let the user pick any file. Null when they picked nothing.
  static Future<PickedFile?> pick() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Picking a file is only built for Android so far.');
    }
    final r = await _channel.invokeMapMethod<String, dynamic>('pick');
    if (r == null) return null;
    return PickedFile(
      path: r['path'] as String,
      name: r['name'] as String? ?? 'file',
      mime: r['mime'] as String? ?? 'application/octet-stream',
      size: (r['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// Hand a received file to an app that opens its type.
  static Future<void> open(String path, {required String name, required String mime}) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Opening a file is only built for Android so far.');
    }
    await _channel.invokeMethod<void>('open', {'path': path, 'name': name, 'mime': mime});
  }
}
