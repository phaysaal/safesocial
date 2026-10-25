import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/look.dart';

/// A look is numbers applied at draw time; the original is never touched.
/// These pin the matrix against reference pixels, the wire shape, the clamp,
/// and how a post names a look per picture.
void main() {
  List<double> px(Look l, double r, double g, double b) => Look.apply(l.matrix(), r, g, b);

  group('the matrix', () {
    test('no look is the identity', () {
      expect(Look.none.isNone, isTrue);
      expect(px(Look.none, 10, 128, 240), [10, 128, 240]);
    });

    test('a stop of exposure doubles every channel, clamped at white', () {
      expect(px(const Look(exposure: 1), 10, 64, 200), [20, 128, 255]);
      expect(px(const Look(exposure: -1), 10, 64, 200), [5, 32, 100]);
    });

    test('warmth raises red and lowers blue on a grey; cool does the reverse', () {
      final warm = px(const Look(temperature: 1), 128, 128, 128);
      expect(warm[0], greaterThan(128));
      expect(warm[1], 128);
      expect(warm[2], lessThan(128));
      final cool = px(const Look(temperature: -1), 128, 128, 128);
      expect(cool[0], lessThan(128));
      expect(cool[2], greaterThan(128));
    });

    test('saturation at minus one is grey, weighted to luminance', () {
      final grey = px(const Look(saturation: -1), 255, 0, 0);
      expect(grey[0], closeTo(grey[1], 1e-6));
      expect(grey[1], closeTo(grey[2], 1e-6));
      expect(grey[0], closeTo(255 * 0.2126, 1e-6));
    });

    test('contrast pivots on mid grey', () {
      expect(px(const Look(contrast: 1), 128, 128, 128)[0], closeTo(128, 1e-6));
      expect(px(const Look(contrast: 1), 200, 200, 200)[0], greaterThan(200));
      expect(px(const Look(contrast: 1), 50, 50, 50)[0], lessThan(50));
      expect(px(const Look(contrast: -1), 200, 200, 200)[0], lessThan(200));
    });

    test('shadows lift the floor; highlights pull the ceiling', () {
      expect(px(const Look(shadows: 1), 0, 0, 0)[0], 30);
      expect(px(const Look(highlights: -1), 255, 255, 255)[0], lessThan(255));
    });

    test('a preset is a look with a name, and every preset parses back to itself', () {
      for (final p in Look.presets) {
        expect(p.preset, isNotNull);
        final back = Look.tryParse(p.toJson())!;
        expect(back.toJson(), p.toJson(), reason: p.preset);
        expect(back.label, p.preset);
      }
    });
  });

  group('the wire', () {
    test('only what is not zero travels; nothing travels for no look', () {
      expect(Look.none.toJson(), isEmpty);
      expect(const Look(exposure: 0.5).toJson(), {'ex': 0.5});
    });

    test('every field is clamped and anything that is not a number is zero', () {
      final l = Look.tryParse({'ex': 9, 'te': -5, 'vg': -1, 'gr': 2, 'co': 'loud', 'p': 'x' * 50})!;
      expect(l.exposure, 2);
      expect(l.temperature, -1);
      expect(l.vignette, 0);
      expect(l.grain, 1);
      expect(l.contrast, 0);
      expect(l.preset, isNull, reason: 'too long a name is no name');
      expect(Look.tryParse('nope'), isNull);
      expect(Look.tryParse(null), isNull);
    });

    test('a post names a look per picture, or one for all', () {
      const a = Look(exposure: 0.3), b = Look(temperature: 0.2);
      expect(Look.payloadFor([Look.none, Look.none]), isNull);
      expect(Look.payloadFor([a, b]), {'0': a.toJson(), '1': b.toJson()});
      expect(Look.payloadFor([a, a, a]), {'*': a.toJson()});
      expect(Look.payloadFor([a, Look.none]), {'0': a.toJson()});

      final payload = {'look': Look.payloadFor([a, b])};
      expect(Look.forIndex(payload, 1).temperature, 0.2);
      expect(Look.forIndex(payload, 2).isNone, isTrue);
      expect(Look.forIndex({'look': Look.payloadFor([a, a])}, 7).exposure, 0.3, reason: '"*" covers every index');
      expect(Look.forIndex(null, 0).isNone, isTrue);
      expect(Look.forIndex({'look': 'junk'}, 0).isNone, isTrue);
    });

    test('rides the viewer route as a query and comes back the same', () {
      final l = Look.presets.first;
      expect(Look.fromQuery(l.toQuery()).toJson(), l.toJson());
      expect(Look.fromQuery(null).isNone, isTrue);
      expect(Look.fromQuery('%7Bnot json').isNone, isTrue);
    });

    test('a moved slider makes the look the person\'s own and drops the preset name', () {
      final mine = Look.presets.first.copyWith(exposure: 0.4, clearPreset: true);
      expect(mine.preset, isNull);
      expect(mine.label, 'Adjusted');
      expect(mine.temperature, Look.presets.first.temperature, reason: 'the rest of the preset stays');
    });
  });

  group('true skin', () {
    test('a neutral, well-lit picture gets nothing but the name', () {
      final l = Look.trueSkin(const ImageStats(meanR: 120, meanG: 121, meanB: 119, medianLuma: 128));
      expect(l.temperature, 0);
      expect(l.tint, 0);
      expect(l.shadows, 0);
      expect(l.exposure, 0);
      expect(l.preset, 'True skin');
    });

    test('a kitchen bulb (amber cast) is cooled; a blue cast is warmed; both clipped', () {
      final bulb = Look.trueSkin(const ImageStats(meanR: 170, meanG: 130, meanB: 80, medianLuma: 120));
      expect(bulb.temperature, lessThan(0));
      expect(bulb.temperature, greaterThanOrEqualTo(-0.6));
      final shade = Look.trueSkin(const ImageStats(meanR: 90, meanG: 120, meanB: 170, medianLuma: 120));
      expect(shade.temperature, greaterThan(0));
      expect(shade.temperature, lessThanOrEqualTo(0.6));
    });

    test('office tubes (green cast) get magenta back', () {
      final tubes = Look.trueSkin(const ImageStats(meanR: 110, meanG: 140, meanB: 110, medianLuma: 120));
      expect(tubes.tint, greaterThan(0));
      expect(tubes.tint, lessThanOrEqualTo(0.4));
    });

    test('sunk midtones are lifted, and a dark picture gets a little exposure too', () {
      final dim = Look.trueSkin(const ImageStats(meanR: 60, meanG: 60, meanB: 60, medianLuma: 55));
      expect(dim.shadows, closeTo(0.45, 1e-9));
      expect(dim.exposure, 0.2);
      final mid = Look.trueSkin(const ImageStats(meanR: 90, meanG: 90, meanB: 90, medianLuma: 90));
      expect(mid.shadows, closeTo(0.1, 1e-9));
      expect(mid.exposure, 0);
    });

    test('stats come from samples: means per channel and the median brightness', () {
      final s = ImageStats.fromSamples([255, 0, 0, 0, 255, 0, 0, 0, 255]);
      expect(s.meanR, 85);
      expect(s.meanG, 85);
      expect(s.meanB, 85);
      expect(s.medianLuma, closeTo(255 * 0.2126, 1e-9), reason: 'the middle of the three lumas, sorted');
      expect(ImageStats.fromSamples(const []).meanR, 0);
    });
  });
}
