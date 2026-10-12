import 'package:flutter/services.dart';

/// The window's screenshot setting, and word of a capture where the platform
/// can only tell us afterwards.
///
/// Android has a window flag that blanks the app in screenshots, screen
/// recordings and the recents switcher; `secure(true)` sets it and the
/// result says whether it took. iOS has no such flag, so there the call
/// answers false and the viewer says so, and the runner reports a screenshot
/// or a screen recording after the fact through [onCapture] so the picture
/// can hide at once. Where there is no platform code at all (tests, desktop),
/// `secure` answers false: the house rule is that nothing claims a protection
/// it did not get.
class ScreenGuard {
  static const channel = MethodChannel('spheres/screen');

  /// Called with 'screenshot' or 'recording' when the platform noticed one.
  static void Function(String kind)? onCapture;

  static bool _listening = false;

  static Future<bool> secure(bool on) async {
    _listen();
    try {
      return await channel.invokeMethod<bool>('secure', {'on': on}) == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'screenshot' || call.method == 'recording') {
        onCapture?.call(call.method);
      }
    });
  }
}
