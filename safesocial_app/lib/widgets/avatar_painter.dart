import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/avatar_spec.dart';

/// Draws an [AvatarSpec]: a round face on a coloured background, with hair,
/// eyes, mouth, glasses and an extra, and optionally an expression for a
/// sticker. Pure drawing; the same spec gives the same picture anywhere.
class AvatarPainter extends CustomPainter {
  final AvatarSpec spec;
  final AvatarExpression expression;
  const AvatarPainter(this.spec, {this.expression = AvatarExpression.plain});

  static const skinColors = [
    Color(0xFFFFE0BD), Color(0xFFF1C27D), Color(0xFFE0AC69), Color(0xFFC68642), Color(0xFF8D5524), Color(0xFF5C3A21),
  ];
  static const hairColors = [
    Color(0xFF2B1B0E), Color(0xFF6D4C2A), Color(0xFFD9A05B), Color(0xFFB13A1F), Color(0xFF9E9E9E), Color(0xFF7E57C2),
  ];
  static const backgrounds = [
    Color(0xFFB3E5FC), Color(0xFFC8E6C9), Color(0xFFFFE0B2), Color(0xFFF8BBD0), Color(0xFFD1C4E9), Color(0xFFECEFF1),
  ];
  static const hairNames = ['None', 'Short', 'Long', 'Curly', 'Bun', 'Cap', 'Mohawk'];
  static const eyeNames = ['Round', 'Almond', 'Happy'];
  static const mouthNames = ['Smile', 'Neutral', 'Open', 'Grin'];
  static const glassesNames = ['None', 'Round', 'Square'];
  static const extraNames = ['None', 'Earrings', 'Beard', 'Freckles'];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(size.width / 2, size.height / 2);
    final paint = Paint()..style = PaintingStyle.fill;

    // Background
    paint.color = backgrounds[spec.background];
    canvas.drawRect(Offset.zero & size, paint);

    final skin = skinColors[spec.skin];
    final hair = hairColors[spec.hairColor];
    final faceR = s * 0.30;
    final faceC = c.translate(0, s * 0.05);

    // Back hair (long / curly) behind the face.
    paint.color = hair;
    if (spec.hair == 2) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: faceC.translate(0, s * 0.12), width: faceR * 2.3, height: faceR * 2.6), Radius.circular(faceR * 0.6)),
          paint);
    } else if (spec.hair == 3) {
      for (var i = 0; i < 9; i++) {
        final a = -1.0 + i * 0.25;
        canvas.drawCircle(faceC.translate(faceR * 1.05 * (a).clamp(-1, 1) * 1.0, -faceR * 0.55 + (i.isEven ? 0 : faceR * 0.35)), faceR * 0.33, paint);
      }
    }

    // Neck and shoulders
    paint.color = skin;
    canvas.drawRect(Rect.fromCenter(center: faceC.translate(0, faceR * 1.15), width: faceR * 0.7, height: faceR * 0.7), paint);
    paint.color = const Color(0xFF455A64);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: faceC.translate(0, faceR * 2.0), width: faceR * 2.8, height: faceR * 1.6), Radius.circular(faceR * 0.5)),
        paint);

    // Ears
    paint.color = skin;
    canvas.drawCircle(faceC.translate(-faceR * 0.98, 0), faceR * 0.18, paint);
    canvas.drawCircle(faceC.translate(faceR * 0.98, 0), faceR * 0.18, paint);
    if (spec.extra == 1) {
      paint.color = const Color(0xFFFFC107);
      canvas.drawCircle(faceC.translate(-faceR * 1.0, faceR * 0.18), faceR * 0.07, paint);
      canvas.drawCircle(faceC.translate(faceR * 1.0, faceR * 0.18), faceR * 0.07, paint);
    }

    // Face
    paint.color = skin;
    canvas.drawOval(Rect.fromCenter(center: faceC, width: faceR * 2, height: faceR * 2.15), paint);

    // Freckles
    if (spec.extra == 3) {
      paint.color = const Color(0x55000000);
      for (final dx in [-0.45, -0.3, -0.15, 0.15, 0.3, 0.45]) {
        canvas.drawCircle(faceC.translate(faceR * dx, faceR * 0.2 + (dx.abs() * faceR * 0.1)), faceR * 0.03, paint);
      }
    }

    // Beard
    if (spec.extra == 2) {
      paint.color = hair;
      final path = Path()
        ..addArc(Rect.fromCenter(center: faceC.translate(0, faceR * 0.1), width: faceR * 2, height: faceR * 2.1), 0.3, 2.55)
        ..close();
      canvas.drawPath(path, paint);
      paint.color = skin;
      canvas.drawOval(Rect.fromCenter(center: faceC.translate(0, faceR * 0.55), width: faceR * 0.9, height: faceR * 0.5), paint);
    }

    // Front hair
    paint.color = hair;
    switch (spec.hair) {
      case 1: // short
        canvas.drawArc(Rect.fromCenter(center: faceC.translate(0, -faceR * 0.05), width: faceR * 2.1, height: faceR * 2.1), 3.3, 2.9, true, paint);
      case 2: // long: fringe
        canvas.drawArc(Rect.fromCenter(center: faceC.translate(0, 0), width: faceR * 2.1, height: faceR * 2.1), 3.4, 2.7, true, paint);
      case 3: // curly front
        for (var i = 0; i < 7; i++) {
          canvas.drawCircle(faceC.translate(-faceR * 0.9 + i * faceR * 0.3, -faceR * 0.85), faceR * 0.28, paint);
        }
      case 4: // bun
        canvas.drawArc(Rect.fromCenter(center: faceC, width: faceR * 2.05, height: faceR * 2.1), 3.3, 2.9, true, paint);
        canvas.drawCircle(faceC.translate(0, -faceR * 1.15), faceR * 0.32, paint);
      case 5: // cap
        paint.color = const Color(0xFFD32F2F);
        canvas.drawArc(Rect.fromCenter(center: faceC.translate(0, -faceR * 0.05), width: faceR * 2.15, height: faceR * 2.15), 3.25, 3.0, true, paint);
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: faceC.translate(faceR * 0.55, -faceR * 0.42), width: faceR * 1.2, height: faceR * 0.2), const Radius.circular(6)),
            paint);
      case 6: // mohawk
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: faceC.translate(0, -faceR * 1.1), width: faceR * 0.5, height: faceR * 0.9), Radius.circular(faceR * 0.2)),
            paint);
      default:
        break;
    }

    // Eyes
    final eyeY = faceC.dy - faceR * 0.15;
    final eyeDx = faceR * 0.38;
    final eyeR = faceR * 0.11;
    paint.color = const Color(0xFF263238);
    final closed = expression == AvatarExpression.sleep || expression == AvatarExpression.laugh;
    final hearts = expression == AvatarExpression.love;
    final tears = expression == AvatarExpression.cry;
    for (final side in [-1, 1]) {
      final e = Offset(faceC.dx + side * eyeDx, eyeY);
      if (hearts) {
        paint.color = const Color(0xFFE53935);
        _heart(canvas, e, eyeR * 1.6, paint);
        paint.color = const Color(0xFF263238);
      } else if (closed || spec.eyes == 2) {
        final arc = Paint()
          ..color = const Color(0xFF263238)
          ..style = PaintingStyle.stroke
          ..strokeWidth = eyeR * 0.45
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(Rect.fromCenter(center: e.translate(0, eyeR * 0.5), width: eyeR * 2.4, height: eyeR * 1.8), 3.3, 2.8, false, arc);
      } else if (spec.eyes == 1) {
        canvas.drawOval(Rect.fromCenter(center: e, width: eyeR * 2.4, height: eyeR * 1.5), paint);
      } else {
        canvas.drawCircle(e, eyeR, paint);
        paint.color = Colors.white;
        canvas.drawCircle(e.translate(-eyeR * 0.3, -eyeR * 0.3), eyeR * 0.3, paint);
        paint.color = const Color(0xFF263238);
      }
      if (tears) {
        paint.color = const Color(0xFF4FC3F7);
        canvas.drawOval(Rect.fromCenter(center: e.translate(0, eyeR * 2.2), width: eyeR * 0.8, height: eyeR * 1.6), paint);
        paint.color = const Color(0xFF263238);
      }
    }

    // Glasses
    if (spec.glasses > 0) {
      final g = Paint()
        ..color = const Color(0xFF37474F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = faceR * 0.06;
      for (final side in [-1, 1]) {
        final e = Offset(faceC.dx + side * eyeDx, eyeY);
        if (spec.glasses == 1) {
          canvas.drawCircle(e, eyeR * 2.2, g);
        } else {
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: e, width: eyeR * 4.4, height: eyeR * 3.2), const Radius.circular(6)), g);
        }
      }
      canvas.drawLine(Offset(faceC.dx - eyeDx + eyeR * 2.2, eyeY), Offset(faceC.dx + eyeDx - eyeR * 2.2, eyeY), g);
    }

    // Mouth
    final mouthC = faceC.translate(0, faceR * 0.45);
    final m = Paint()
      ..color = const Color(0xFF8D2B2B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = faceR * 0.07
      ..strokeCap = StrokeCap.round;
    final mouth = switch (expression) {
      AvatarExpression.laugh || AvatarExpression.thumbsUp => 3,
      AvatarExpression.cry => 4,
      AvatarExpression.sleep => 1,
      _ => spec.mouth,
    };
    switch (mouth) {
      case 0: // smile
        canvas.drawArc(Rect.fromCenter(center: mouthC.translate(0, -faceR * 0.1), width: faceR * 0.8, height: faceR * 0.6), 0.4, 2.3, false, m);
      case 1: // neutral
        canvas.drawLine(mouthC.translate(-faceR * 0.3, 0), mouthC.translate(faceR * 0.3, 0), m);
      case 2: // open
        paint.color = const Color(0xFF8D2B2B);
        canvas.drawOval(Rect.fromCenter(center: mouthC, width: faceR * 0.45, height: faceR * 0.5), paint);
      case 3: // grin
        paint.color = const Color(0xFF8D2B2B);
        final path = Path()..addArc(Rect.fromCenter(center: mouthC.translate(0, -faceR * 0.12), width: faceR * 0.95, height: faceR * 0.8), 0.2, 2.75);
        path.close();
        canvas.drawPath(path, paint);
        paint.color = Colors.white;
        canvas.drawRect(Rect.fromCenter(center: mouthC.translate(0, -faceR * 0.05), width: faceR * 0.7, height: faceR * 0.14), paint);
      case 4: // sad
        canvas.drawArc(Rect.fromCenter(center: mouthC.translate(0, faceR * 0.25), width: faceR * 0.7, height: faceR * 0.5), 3.5, 2.4, false, m);
    }

    // Expression extras
    paint.color = skin;
    switch (expression) {
      case AvatarExpression.wave:
        canvas.drawCircle(faceC.translate(faceR * 1.45, faceR * 0.9), faceR * 0.34, paint);
        for (var i = 0; i < 4; i++) {
          canvas.drawRRect(
              RRect.fromRectAndRadius(Rect.fromCenter(center: faceC.translate(faceR * (1.2 + i * 0.17), faceR * 0.5), width: faceR * 0.14, height: faceR * 0.5), Radius.circular(faceR * 0.07)),
              paint);
        }
      case AvatarExpression.thumbsUp:
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: faceC.translate(faceR * 1.45, faceR * 1.0), width: faceR * 0.55, height: faceR * 0.5), Radius.circular(faceR * 0.12)),
            paint);
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: faceC.translate(faceR * 1.3, faceR * 0.55), width: faceR * 0.2, height: faceR * 0.55), Radius.circular(faceR * 0.1)),
            paint);
      case AvatarExpression.sleep:
        final tp = TextPainter(
            text: TextSpan(text: 'z Z', style: TextStyle(color: const Color(0xFF37474F), fontSize: faceR * 0.5, fontWeight: FontWeight.w700)),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, faceC.translate(faceR * 0.9, -faceR * 1.2));
      case AvatarExpression.laugh:
        paint.color = const Color(0xFF4FC3F7);
        canvas.drawOval(Rect.fromCenter(center: faceC.translate(-faceR * 0.75, faceR * 0.05), width: faceR * 0.16, height: faceR * 0.3), paint);
      default:
        break;
    }
  }

  void _heart(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path()
      ..moveTo(c.dx, c.dy + r * 0.9)
      ..cubicTo(c.dx - r * 1.6, c.dy - r * 0.2, c.dx - r * 0.6, c.dy - r * 1.3, c.dx, c.dy - r * 0.4)
      ..cubicTo(c.dx + r * 0.6, c.dy - r * 1.3, c.dx + r * 1.6, c.dy - r * 0.2, c.dx, c.dy + r * 0.9)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant AvatarPainter old) => old.spec != spec || old.expression != expression;

  /// The avatar as PNG bytes, [size] pixels square.
  static Future<Uint8List> renderPng(AvatarSpec spec, {int size = 512, AvatarExpression expression = AvatarExpression.plain}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    AvatarPainter(spec, expression: expression).paint(canvas, Size(size.toDouble(), size.toDouble()));
    final image = await recorder.endRecording().toImage(size, size);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('Could not encode the avatar');
    return data.buffer.asUint8List();
  }
}
