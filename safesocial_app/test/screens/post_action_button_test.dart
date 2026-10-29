import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/widgets/post_card.dart';

/// Found on the Samsung, 27 October 2026: a long press on a post's reaction
/// button showed its tooltip and the reaction set never opened, because the
/// long press was handled outside the button and the tooltip inside won.
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('a long press opens the reaction set and shows no tooltip', (tester) async {
    var longPressed = 0, tapped = 0;
    await tester.pumpWidget(host(PostActionButton(
      icon: Icons.add_reaction_outlined,
      label: 'Respect',
      color: Colors.grey,
      onTap: () => tapped++,
      onLongPress: () => longPressed++,
    )));
    await tester.longPress(find.byType(PostActionButton));
    await tester.pumpAndSettle();
    expect(longPressed, 1);
    expect(tapped, 0);
    expect(find.text('Respect'), findsNothing, reason: 'the tooltip did not take the long press');

    await tester.tap(find.byType(PostActionButton));
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  testWidgets('a button without a long press keeps its tooltip', (tester) async {
    await tester.pumpWidget(host(PostActionButton(
      icon: Icons.forum_outlined,
      label: 'Comment',
      color: Colors.grey,
      onTap: () {},
    )));
    await tester.longPress(find.byType(PostActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Comment'), findsOneWidget);
  });
}
