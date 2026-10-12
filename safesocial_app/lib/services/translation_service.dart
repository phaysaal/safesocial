import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'secure_store.dart';

/// What a translator must do. The real one wraps ML Kit on the device; tests
/// use a fake. Nothing a person translates ever leaves the device; only the
/// language models are fetched, once, and only when the person asks.
abstract class Translator {
  /// A BCP-47 code such as `fr`, or null when the language is not clear.
  Future<String?> identify(String text);
  Future<String> translate(String text, {required String from, required String to});
  Future<bool> hasModel(String code);
  Future<void> downloadModel(String code);
  Future<void> deleteModel(String code);

  /// Every language the translator can work with, as (code, name).
  List<(String, String)> get languages;
}

/// One translated piece of text and where it came from.
class Translation {
  final String text;
  final String from;
  const Translation(this.text, this.from);
}

/// Opt-in, on-device translation of posts, comments and messages.
///
/// Off by default. Turning it on downloads nothing by itself; each language
/// model is fetched from Google's servers when the person taps download, and
/// Settings says so in those words. Translations are kept in memory for the
/// session, by the id of the thing translated.
class TranslationService extends ChangeNotifier {
  static const _key = 'spheres_translation_v1';

  final Translator _translator;
  TranslationService(this._translator);

  bool _enabled = false;
  String _target = 'en';
  final Map<String, Translation> _translations = {};
  final Set<String> _busy = {};
  final Map<String, String> _errors = {};

  bool get enabled => _enabled;
  String get target => _target;
  List<(String, String)> get languages => _translator.languages;

  Translation? of(String id) => _translations[id];
  bool isBusy(String id) => _busy.contains(id);
  String? errorFor(String id) => _errors[id];

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    if (!on) _translations.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> setTarget(String code) async {
    if (!languages.any((l) => l.$1 == code)) throw ArgumentError('Unknown language $code');
    _target = code;
    _translations.clear();
    await _persist();
    notifyListeners();
  }

  Future<bool> hasModel(String code) => _translator.hasModel(code);

  Future<void> downloadModel(String code) async {
    await _translator.downloadModel(code);
    notifyListeners();
  }

  Future<void> deleteModel(String code) async {
    await _translator.deleteModel(code);
    notifyListeners();
  }

  /// Translate [text] into the target language and remember it under [id].
  /// Throws when translation is off, the language cannot be told, or a model
  /// is missing; the message says which.
  Future<Translation> translate(String id, String text) async {
    if (!_enabled) throw StateError('Translation is off. Turn it on in Settings.');
    final cached = _translations[id];
    if (cached != null) return cached;
    _busy.add(id);
    _errors.remove(id);
    notifyListeners();
    try {
      final from = await _translator.identify(text);
      if (from == null) throw StateError('Could not tell which language this is.');
      if (from == _target) {
        final same = Translation(text, from);
        _translations[id] = same;
        return same;
      }
      if (!await _translator.hasModel(from) || !await _translator.hasModel(_target)) {
        throw StateError('The $from or $_target model is not on this device. Download it in Settings, Translation.');
      }
      final out = await _translator.translate(text, from: from, to: _target);
      final t = Translation(out, from);
      _translations[id] = t;
      return t;
    } catch (e) {
      _errors[id] = '$e'.replaceFirst('Bad state: ', '');
      rethrow;
    } finally {
      _busy.remove(id);
      notifyListeners();
    }
  }

  void clear(String id) {
    _translations.remove(id);
    _errors.remove(id);
    notifyListeners();
  }

  Future<void> _persist() =>
      SecureStore.instance.setString(_key, jsonEncode({'enabled': _enabled, 'target': _target}));

  Future<void> load() async {
    final raw = await SecureStore.instance.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map;
      _enabled = j['enabled'] == true;
      if (j['target'] is String) _target = j['target'] as String;
    } catch (_) {}
  }
}
