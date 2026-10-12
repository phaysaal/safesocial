import 'dart:io';

import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'translation_service.dart';

/// Google ML Kit's on-device translation. The models are downloaded from
/// Google when asked for and run on the phone afterwards; the text being
/// translated never leaves it. Only on Android and iOS; elsewhere every call
/// says so.
class MlKitTranslator implements Translator {
  final _models = OnDeviceTranslatorModelManager();
  final _identifier = LanguageIdentifier(confidenceThreshold: 0.5);

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  void _require() {
    if (!supported) throw UnsupportedError('On-device translation is only built for Android and iOS.');
  }

  static TranslateLanguage _lang(String code) {
    final l = BCP47Code.fromRawValue(code);
    if (l == null) throw ArgumentError('No model exists for "$code"');
    return l;
  }

  @override
  List<(String, String)> get languages =>
      [for (final l in TranslateLanguage.values) (l.bcpCode, l.name)]..sort((a, b) => a.$2.compareTo(b.$2));

  @override
  Future<String?> identify(String text) async {
    _require();
    final code = await _identifier.identifyLanguage(text);
    return code == 'und' ? null : code;
  }

  @override
  Future<String> translate(String text, {required String from, required String to}) async {
    _require();
    final t = OnDeviceTranslator(sourceLanguage: _lang(from), targetLanguage: _lang(to));
    try {
      return await t.translateText(text);
    } finally {
      await t.close();
    }
  }

  @override
  Future<bool> hasModel(String code) async {
    _require();
    return _models.isModelDownloaded(_lang(code).bcpCode);
  }

  @override
  Future<void> downloadModel(String code) async {
    _require();
    final ok = await _models.downloadModel(_lang(code).bcpCode, isWifiRequired: false);
    if (!ok) throw StateError('The $code model could not be downloaded.');
  }

  @override
  Future<void> deleteModel(String code) async {
    _require();
    await _models.deleteModel(_lang(code).bcpCode);
  }
}
