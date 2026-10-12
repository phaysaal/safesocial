import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/avatar_spec.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/translation_service.dart';
import 'package:spheres_app/widgets/avatar_painter.dart';

/// A fake translator that behaves like the real one would: it knows a few
/// languages, holds models only when asked, and refuses what it cannot tell.
class _Fake implements Translator {
  final Set<String> models = {};
  final calls = <String>[];
  @override
  List<(String, String)> get languages => const [('en', 'English'), ('fr', 'French'), ('bn', 'Bengali')];
  @override
  Future<String?> identify(String text) async {
    if (text.startsWith('fr:')) return 'fr';
    if (text.startsWith('en:')) return 'en';
    return null;
  }
  @override
  Future<String> translate(String text, {required String from, required String to}) async {
    calls.add('$from>$to');
    return '[$to] ${text.substring(3).trim()}';
  }
  @override
  Future<bool> hasModel(String code) async => models.contains(code);
  @override
  Future<void> downloadModel(String code) async => models.add(code);
  @override
  Future<void> deleteModel(String code) async => models.remove(code);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  group('translation', () {
    test('is off until opted in, needs both models, translates on the device and caches', () async {
      final fake = _Fake();
      final t = TranslationService(fake);
      await t.load();
      expect(t.enabled, isFalse);
      expect(() => t.translate('m1', 'fr: bonjour'), throwsStateError);

      await t.setEnabled(true);
      await expectLater(t.translate('m1', 'fr: bonjour'), throwsStateError, reason: 'no models yet');
      expect(t.errorFor('m1'), contains('not on this device'));
      await t.downloadModel('fr');
      await t.downloadModel('en');
      final tr = await t.translate('m1', 'fr: bonjour');
      expect(tr.text, '[en] bonjour');
      expect(tr.from, 'fr');
      expect(t.of('m1')!.text, '[en] bonjour');
      await t.translate('m1', 'fr: bonjour');
      expect(fake.calls, ['fr>en'], reason: 'the second time is from the cache');

      await expectLater(t.translate('m2', 'zz: ???'), throwsStateError);
      expect(t.errorFor('m2'), contains('which language'));

      final same = await t.translate('m3', 'en: hello');
      expect(same.text, 'en: hello', reason: 'already in the target language');
      expect(fake.calls, ['fr>en']);

      await t.setTarget('bn');
      expect(t.of('m1'), isNull, reason: 'a new target clears what was shown');
      expect(() => t.setTarget('xx'), throwsArgumentError);
      t.clear('m3');
      expect(t.of('m3'), isNull);

      final again = TranslationService(_Fake());
      await again.load();
      expect(again.enabled, isTrue);
      expect(again.target, 'bn');
      await again.setEnabled(false);
      expect(again.enabled, isFalse);
    });
  });

  group('avatar', () {
    test('a spec round-trips and bad values fall back', () {
      const s = AvatarSpec(skin: 4, hair: 6, hairColor: 5, eyes: 2, mouth: 3, glasses: 2, extra: 3, background: 5);
      expect(AvatarSpec.fromJson(s.toJson()), s);
      final bad = AvatarSpec.fromJson({'skin': 99, 'hair': -1, 'eyes': 'x'});
      expect(bad.skin, 0);
      expect(bad.hair, 0);
      expect(bad.eyes, 0);
    });

    testWidgets('renders a PNG of the asked size, different per spec and expression', (tester) async {
      // Image encoding happens off the test clock.
      final out = await tester.runAsync(() async => [
            await AvatarPainter.renderPng(const AvatarSpec(), size: 64),
            await AvatarPainter.renderPng(const AvatarSpec(hair: 3, glasses: 1), size: 64),
            await AvatarPainter.renderPng(const AvatarSpec(), size: 64, expression: AvatarExpression.love),
          ]);
      final [a, b, c] = out!;
      for (final bytes in [a, b, c]) {
        final decoded = img.decodePng(Uint8List.fromList(bytes));
        expect(decoded, isNotNull);
        expect(decoded!.width, 64);
      }
      expect(a, isNot(equals(b)));
      expect(a, isNot(equals(c)));
    });
  });
}
