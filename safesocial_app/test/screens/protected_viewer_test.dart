import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:spheres_app/models/media_protection.dart';
import 'package:spheres_app/screens/media/protected_media_screen.dart';
import 'package:spheres_app/widgets/protected_veil.dart';

/// Protected media: shown while two fingers are on the glass, for ten seconds
/// at a time, blurred otherwise; the screen says plainly when the window
/// cannot refuse screenshots, which is the case wherever there is no platform
/// code, tests included.
void main() {
  group('the hold rule', () {
    test('two fingers show, one does not, lifting one hides at once', () {
      final gate = HoldGate();
      expect(gate.showing, isFalse);
      gate.down(1);
      expect(gate.showing, isFalse, reason: 'one finger is a tap, not a hold');
      gate.down(2);
      expect(gate.showing, isTrue);
      gate.up(2);
      expect(gate.showing, isFalse);
      gate.down(2);
      expect(gate.showing, isTrue, reason: 'a second hold counts again');
    });

    test('after the time is up every finger has to lift before it shows again', () {
      final gate = HoldGate();
      gate.down(1);
      gate.down(2);
      gate.expire();
      expect(gate.showing, isFalse);
      gate.up(2);
      gate.down(2);
      expect(gate.showing, isFalse, reason: 'one finger stayed down the whole time');
      gate.up(1);
      gate.up(2);
      gate.down(1);
      gate.down(2);
      expect(gate.showing, isTrue);
    });

    test('a reset forgets the fingers, so the background cannot keep it shown', () {
      final gate = HoldGate();
      gate.down(1);
      gate.down(2);
      gate.reset();
      expect(gate.showing, isFalse);
      expect(gate.pointers, 0);
    });
  });

  group('the scan band', () {
    test('three frames cover the whole picture, a third each, in stripes that step down', () {
      const size = Size(300, 900);
      final frames = [for (var f = 0; f < 3; f++) ScanBand.sharp(f, size)];
      for (final rects in frames) {
        expect(rects.fold(0.0, (a, r) => a + r.height), 300.0, reason: 'constant brightness');
      }
      expect(frames[0].map((r) => r.top), [0.0, 300.0, 600.0]);
      expect(frames[1].map((r) => r.top), [100.0, 400.0, 700.0], reason: 'steps down a stripe');
      final covered = {for (final rects in frames) for (final r in rects) r.top};
      expect(covered.length, 9, reason: 'every stripe is sharp once in three frames');
      expect(ScanBand.sharp(3, size), frames[0], reason: 'and round again');
    });
  });

  group('the protection flag', () {
    test('reads from a payload and survives the viewer route', () {
      expect(MediaProtection.fromPayload(null), isNull);
      expect(MediaProtection.fromPayload({'bg': 'x'}), isNull);
      expect(MediaProtection.fromPayload({'protected': {}})!.watermark, isFalse);
      expect(MediaProtection.fromPayload({'protected': {'wm': true}})!.watermark, isTrue);
      expect(MediaProtection.fromPayload({'protected': 'yes'}), isNotNull,
          reason: 'a malformed value still protects');
      const p = MediaProtection(watermark: true);
      final q = Uri.parse('/x?ref=r${p.query}').queryParameters;
      expect(MediaProtection.fromQuery(q), p);
      expect(MediaProtection.fromQuery({'ref': 'r'}), isNull);
    });
  });

  group('the viewer', () {
    Uint8List picture() {
      final image = img.Image(width: 40, height: 30);
      img.fill(image, color: img.ColorRgb8(20, 120, 220));
      return Uint8List.fromList(img.encodeJpg(image));
    }

    testWidgets('shows while two fingers are down, hides when one lifts, and after ten seconds',
        (tester) async {
      final bytes = picture();
      final dir = await tester.runAsync(() async {
        final f = await _tempFile(bytes);
        return f;
      });
      await tester.runAsync(() => tester.pumpWidget(MaterialApp(
            home: ProtectedMediaScreen(
                mediaRef: dir!, protection: const MediaProtection(watermark: true), viewerName: 'Al'),
          )));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(find.byType(ProtectedVeil), findsOneWidget, reason: 'the picture decoded');
      expect(find.text('Hold with two fingers to see it'), findsOneWidget);
      expect(find.byKey(const Key('no-secure-flag')), findsOneWidget,
          reason: 'no platform here: the screen says screenshots are not blocked');
      expect(find.text('Al'), findsNothing, reason: 'no watermark while hidden');

      final centre = tester.getCenter(find.byType(ProtectedVeil));
      final one = await tester.startGesture(centre, pointer: 1);
      await tester.pump();
      expect(find.text('Hold with two fingers to see it'), findsOneWidget);

      final two = await tester.startGesture(centre + const Offset(40, 0), pointer: 2);
      await tester.pump();
      expect(find.text('Hold with two fingers to see it'), findsNothing);
      expect(find.text('Al'), findsOneWidget, reason: 'the watermark is on while shown');

      await two.up();
      await tester.pump();
      expect(find.text('Hold with two fingers to see it'), findsOneWidget);

      final again = await tester.startGesture(centre + const Offset(40, 0), pointer: 3);
      await tester.pump();
      expect(find.text('Hold with two fingers to see it'), findsNothing);
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('Hold with two fingers to see it'), findsOneWidget,
          reason: 'ten seconds is the most one hold gives');

      await one.up();
      await again.up();
      await tester.pump();
      // Leave the screen so its ticker and timer are gone before the test ends.
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
    });
  });
}

Future<String> _tempFile(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('spheres_protected_');
  final f = File('${dir.path}/p.jpg');
  await f.writeAsBytes(bytes);
  return f.path;
}
