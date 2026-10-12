import 'dart:io';

import 'package:flutter/services.dart';

/// Android chat bubbles: a message notification that can float over other
/// apps and opens the chat in a small window. The notification is built on
/// the device from already-decrypted text, like every other one.
class BubbleBridge {
  BubbleBridge._();

  static const _channel = MethodChannel('spheres/bubbles');

  /// Called with a route when a bubble window attached to the running app
  /// and wants the chat shown.
  static void Function(String route)? onOpenRoute;

  static bool _listening = false;

  /// Start taking "open" calls from the platform. Idempotent.
  static void listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        final route = (call.arguments as Map?)?['route'];
        if (route is String) onOpenRoute?.call(route);
      }
    });
  }

  /// Post a bubble for one chat. Returns false when the platform cannot show
  /// one (older Android, bubbles turned off for the app, or another OS), so
  /// the caller falls back to an ordinary notification.
  static Future<bool> show({
    required String chatKey,
    required String name,
    required String text,
    required int id,
  }) async {
    if (!Platform.isAndroid) return false;
    final ok = await _channel.invokeMethod<bool>('show', {
      'chatKey': chatKey,
      'name': name,
      'text': text,
      'id': id,
    });
    return ok ?? false;
  }
}
