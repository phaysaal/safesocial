import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/widgets/qr_box.dart';

/// A QR code inside an AlertDialog. The bare QR widget sizes itself with a
/// LayoutBuilder, which cannot answer the dialog's intrinsic-width question;
/// the result on a phone was a dimmed screen with no dialog at all. QrBox
/// answers with a fixed size.
void main() {
  testWidgets('a sphere invite link, questions and all, shows in a dialog', (tester) async {
    final link = Uri(scheme: 'spheres', host: 'join', queryParameters: {
      's': 'a' * 64,
      't': 'b' * 32,
      'via': 'c' * 64,
      'n': 'Test Sphere',
      'q': jsonEncode(['Who invited you', 'Favourite colour']),
    }).toString();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Invite link'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  QrBox(data: link),
                  SelectableText(link, style: const TextStyle(fontSize: 11)),
                ]),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Invite link'), findsOneWidget);
    expect(find.byType(QrBox), findsOneWidget);
  });
}
