import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ChangeNotifier {
  static const _key = 'theme_mode';

  ThemeMode _themeMode = ThemeMode.light;

  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode == ThemeMode.dark;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    if (value == 'dark') {
      _themeMode = ThemeMode.dark;
    } else {
      _themeMode = ThemeMode.light;
    }
    _textScale = (prefs.getDouble(_scaleKey) ?? 1.0).clamp(0.85, 1.6);
    _highContrast = prefs.getBool(_contrastKey) ?? false;
    _reducedMotion = prefs.getBool(_motionKey) ?? false;
    notifyListeners();
  }

  Future<void> toggle() async {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, _themeMode == ThemeMode.dark ? 'dark' : 'light');
    notifyListeners();
  }

  static const _scaleKey = 'text_scale';
  static const _contrastKey = 'high_contrast';
  static const _motionKey = 'reduced_motion';
  double _textScale = 1.0;
  bool _highContrast = false;
  bool _reducedMotion = false;

  /// 0.85 to 1.6; the device's own setting multiplies on top.
  double get textScale => _textScale;
  bool get highContrast => _highContrast;
  bool get reducedMotion => _reducedMotion;

  Future<void> setTextScale(double scale) async {
    _textScale = scale.clamp(0.85, 1.6);
    (await SharedPreferences.getInstance()).setDouble(_scaleKey, _textScale);
    notifyListeners();
  }

  Future<void> setHighContrast(bool on) async {
    _highContrast = on;
    (await SharedPreferences.getInstance()).setBool(_contrastKey, on);
    notifyListeners();
  }

  Future<void> setReducedMotion(bool on) async {
    _reducedMotion = on;
    (await SharedPreferences.getInstance()).setBool(_motionKey, on);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode == ThemeMode.dark ? 'dark' : 'light');
    notifyListeners();
  }
}
