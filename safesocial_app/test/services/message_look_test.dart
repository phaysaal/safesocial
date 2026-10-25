import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/models/look.dart';
import 'package:spheres_app/services/chat_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// A look on a sent photo, changed after sending: a chat_edit of numbers,
/// the words and their edit mark untouched, the sender only.
void main() {
  late String alice, aliceSecret, bob;
  late SessionManager aliceSessions;
  late String bobExchange;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(ed.generateKey().publicKey.bytes);
    final aliceExchange = await SpheresCrypto.newKeyExchangeKeyPair();
    aliceSessions = SessionManager();
    await aliceSessions.configure(keyExchangeKeyPair: aliceExchange, identityKey: alice, identitySecret: aliceSecret);
    final bobPair = await SpheresCrypto.newKeyExchangeKeyPair();
    bobExchange = hex.encode((await bobPair.extractPublicKey()).bytes);
  });

  ChatService chatFor() {
    final chat = ChatService();
    chat.setMyInfo(alice, aliceSecret, sessions: aliceSessions, resolveExchangeKey: (k) => k == bob ? bobExchange : null);
    return chat;
  }

  test('the sender sets a look, and it is numbers in the payload, not an edit of the words', () async {
    final chat = chatFor();
    final m = await chat.sendMessage(bob, 'a photo');
    final look = Look.payloadFor([Look.presets.first]);
    await chat.setMessageLook(bob, m.id, look);
    final after = chat.conversations[bob]!.singleWhere((x) => x.id == m.id);
    expect(after.payload?['look'], look);
    expect(after.editedAt, isNull);
    expect(after.content, 'a photo');
    await chat.setMessageLook(bob, m.id, null);
    expect(chat.conversations[bob]!.singleWhere((x) => x.id == m.id).payload?['look'], isNull);
  });

  test('a chat_edit with a look is applied from the sender, removed on null, dropped from anyone else', () async {
    final chat = chatFor();
    final m = await chat.sendMessage(bob, 'a photo');
    final look = {'*': const Look(exposure: 0.5).toJson()};
    chat.applyChatEdit(bob, alice, {'message_id': m.id, 'look': look});
    expect(Look.forIndex(chat.conversations[bob]!.single.payload, 0).exposure, 0.5);
    expect(chat.conversations[bob]!.single.editedAt, isNull);

    chat.applyChatEdit(bob, bob, {'message_id': m.id, 'look': null});
    expect(chat.conversations[bob]!.single.payload?['look'], look, reason: 'Bob did not send it');

    chat.applyChatEdit(bob, alice, {'message_id': m.id, 'content': 'a photo, late', 'edited_at': '2026-10-25T18:00:00Z'});
    expect(chat.conversations[bob]!.single.content, 'a photo, late');
    expect(chat.conversations[bob]!.single.payload?['look'], look, reason: 'an edit of words leaves the look');

    chat.applyChatEdit(bob, alice, {'message_id': m.id, 'look': null});
    expect(chat.conversations[bob]!.single.payload?['look'], isNull);
    expect(chat.conversations[bob]!.single.content, 'a photo, late');
  });
}
