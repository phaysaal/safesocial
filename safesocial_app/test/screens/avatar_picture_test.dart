import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/identity_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/translation_service.dart';
import 'package:spheres_app/widgets/avatar.dart';
import 'package:spheres_app/widgets/message_bubble.dart';

/// Reported on hardware: a contact's picture showed in the chat list and on
/// their profile, but every post, comment and chat bubble still drew their
/// initial. Only the places that were handed `Contact.avatarRef` showed it;
/// the rest only knew the author's key. The avatar now resolves the picture
/// from the key itself, so an old post shows the picture the person has now.
class _NoTranslator implements Translator {
  @override
  List<(String, String)> get languages => const [];
  @override
  Future<String?> identify(String text) async => null;
  @override
  Future<String> translate(String text, {required String from, required String to}) async => text;
  @override
  Future<bool> hasModel(String code) async => false;
  @override
  Future<void> downloadModel(String code) async {}
  @override
  Future<void> deleteModel(String code) async {}
}

void main() {
  // A valid 1x1 PNG, so FileImage can decode it.
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    dir = await Directory.systemTemp.createTemp('avatar_test');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> pump(WidgetTester tester, IdentityService identity, ContactService contacts, Widget child) {
    return tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: identity),
        ChangeNotifierProvider.value(value: contacts),
        ChangeNotifierProvider(create: (_) => TranslationService(_NoTranslator())),
      ],
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    ));
  }

  testWidgets('an avatar given only a contact key shows their picture', (tester) async {
    final file = File('${dir.path}/alice.png')..writeAsBytesSync(png);
    final identity = IdentityService();
    await identity.createIdentity('Me');
    final contacts = ContactService();
    await contacts.addContact('a' * 64, 'Alice');
    contacts.materialiseMedia = (ref) async => file.path;
    await contacts.applyProfile('a' * 64, {'name': 'Alice', 'avatar': 'blob:1'});
    expect(contacts.getContact('a' * 64)!.avatarRef, file.path);

    await tester.runAsync(() => pump(tester, identity, contacts,
        const UserAvatar(displayName: 'Alice', identityKey: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')));
    await tester.pump();

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect((avatar.backgroundImage as FileImage).file.path, file.path);
    expect(find.text('A'), findsNothing, reason: 'the initial gives way to the picture');
  });

  testWidgets('our own key shows our own picture; a stranger keeps the initial', (tester) async {
    final file = File('${dir.path}/me.png')..writeAsBytesSync(png);
    final identity = IdentityService();
    await identity.createIdentity('Faisal');
    await identity.updateAvatar(file.path);
    final contacts = ContactService();

    await tester.runAsync(() => pump(tester, identity, contacts, Row(children: [
          UserAvatar(displayName: 'You', identityKey: identity.publicKey),
          const UserAvatar(displayName: 'Zed', identityKey: 'zzzz'),
        ])));
    await tester.pump();

    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(find.text('Z'), findsOneWidget);
  });

  testWidgets('a received bubble carries the sender beside it; our own never does', (tester) async {
    final identity = IdentityService();
    final contacts = ContactService();
    Message msg(String from) => Message(
        id: from, senderId: from, recipientId: 'x', content: 'hi', timestamp: DateTime(2026, 10, 12));
    const face = Key('face');

    await pump(tester, identity, contacts, Column(children: [
      MessageBubble(message: msg('them'), isMine: false, avatar: const SizedBox(key: face)),
      MessageBubble(message: msg('me'), isMine: true, avatar: const SizedBox(key: Key('mine'))),
    ]));

    expect(find.byKey(face), findsOneWidget);
    expect(find.byKey(const Key('mine')), findsNothing, reason: 'the gutter is only for their side');
  });

  testWidgets('our own avatar labelled "You" shows our initial, not "Y"', (tester) async {
    final identity = IdentityService();
    await identity.createIdentity('Maya');
    final contacts = ContactService();
    await tester.runAsync(() => pump(tester, identity, contacts,
        UserAvatar(displayName: 'You', identityKey: identity.publicKey)));
    await tester.pump();
    expect(find.text('M'), findsOneWidget);
    expect(find.text('Y'), findsNothing);
  });

  testWidgets('someone else\'s avatar keeps the name it is given', (tester) async {
    final identity = IdentityService();
    await identity.createIdentity('Maya');
    final contacts = ContactService();
    await tester.runAsync(() => pump(tester, identity, contacts,
        UserAvatar(displayName: 'Yusuf', identityKey: 'b' * 64)));
    await tester.pump();
    expect(find.text('Y'), findsOneWidget);
  });
}
