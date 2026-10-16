import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/blob.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/models/contact.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/models/profile_about.dart';
import 'package:spheres_app/models/user_profile.dart';
import 'package:spheres_app/services/blob_service.dart';
import 'package:spheres_app/services/chat_service.dart';
import 'package:spheres_app/services/identity_service.dart';
import 'package:spheres_app/services/inbound_events.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/media_service.dart';
import 'package:spheres_app/services/notification_service.dart';
import 'package:spheres_app/services/profile_sharing.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/widgets/message_cards.dart';

/// Messaging comforts: files of any type travel as blobs under their own
/// name; a scheduled message waits on this device and goes at its time;
/// vanish mode is a preset over disappearing messages that puts back what
/// was there; an ignored chat tells its sender nothing; a chat's look is
/// local; a note lasts a day and travels only while it lasts; a bubble is
/// tried for a direct message and the plain notification is the fallback.
class _FakeBlobRelay {
  final Map<String, String> chunks = {};
  Future<http.Response> handle(
      String method, Uri url, Map<String, String> headers, List<int>? body) async {
    final key = '${url.pathSegments[1]}/${url.pathSegments[2]}';
    if (method == 'PUT') {
      if (chunks.containsKey(key)) return http.Response('exists', 409);
      chunks[key] = utf8.decode(body!);
      return http.Response('OK', 200);
    }
    final chunk = chunks[key];
    return chunk == null ? http.Response('', 404) : http.Response(chunk, 200);
  }
}

class _Sink implements NotificationSink {
  final shown = <String>[];
  @override
  Future<void> initialize({required void Function(String route) onTap}) async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show({required int id, required String title, required String body, required String thread, required String route, required bool highPriority}) async =>
      shown.add(body);
  @override
  Future<void> cancelThread(String thread) async {}
  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String route}) async {}
  @override
  Future<void> cancelScheduled(int id) async {}
}

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
    await aliceSessions.configure(
        keyExchangeKeyPair: aliceExchange, identityKey: alice, identitySecret: aliceSecret);
    final bobPair = await SpheresCrypto.newKeyExchangeKeyPair();
    bobExchange = hex.encode((await bobPair.extractPublicKey()).bytes);
  });

  ChatService chatFor() {
    final chat = ChatService();
    chat.setMyInfo(alice, aliceSecret,
        sessions: aliceSessions, resolveExchangeKey: (k) => k == bob ? bobExchange : null);
    return chat;
  }

  group('files', () {
    late Directory tmp;
    setUp(() async {
      BlobService.transportOverride = _FakeBlobRelay().handle;
      tmp = await Directory.systemTemp.createTemp('spheres_files_');
    });
    tearDown(() async {
      BlobService.transportOverride = null;
      await tmp.delete(recursive: true);
    });

    test('a file goes as it is and comes back under its name', () async {
      final f = File('${tmp.path}/notes.pdf');
      final bytes = Uint8List.fromList(List.generate(5000, (i) => (i * 7) % 256));
      await f.writeAsBytes(bytes);
      final ref = await MediaService.prepareFileForRelay(f.path, mimeType: 'application/pdf');
      expect(ref, isNotNull);
      final blob = BlobRef.tryDecode(ref!)!;
      expect(blob.mimeType, 'application/pdf');
      expect(blob.length, bytes.length);
      final back = await MediaService.decodeAndSaveFile(ref, name: 'notes.pdf', into: tmp);
      expect(back, endsWith('_notes.pdf'));
      expect(await File(back!).readAsBytes(), bytes);
      expect(await MediaService.decodeAndSaveFile(back, name: 'x'), back, reason: 'a local path stays');
    });

    test('a file message is described by its name and keeps its payload', () {
      final m = Message(
        id: 'f1', senderId: 'a', recipientId: 'b', content: 'notes.pdf', timestamp: DateTime(2026),
        mediaRefs: const ['/x/notes.pdf'], kind: 'file',
        payload: const {'name': 'notes.pdf', 'mime': 'application/pdf', 'size': 5000},
      );
      expect(ChatService.describeMessage(m), 'File: notes.pdf');
      final back = Message.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(back.kind, 'file');
      expect(back.payload!['mime'], 'application/pdf');
      expect(FileCard.describeSize(5000), '5 KB');
      expect(FileCard.describeSize(3 * 1024 * 1024), '3.0 MB');
    });
  });

  group('scheduled messages', () {
    test('wait on this device, go at their time, and survive a restart', () async {
      final chat = chatFor();
      await chat.loadConversations();
      final at = DateTime.now().add(const Duration(hours: 2));
      final s = await chat.scheduleMessage(bob, 'later', at);
      expect(chat.scheduledFor(bob).single.id, s.id);
      expect(() => chat.scheduleMessage(bob, '  ', at), throwsArgumentError);
      expect(() => chat.scheduleMessage(bob, 'past', DateTime.now().subtract(const Duration(minutes: 1))),
          throwsArgumentError);

      expect(await chat.sendDueScheduled(), 0, reason: 'not yet');
      expect(chat.conversations[bob] ?? const [], isEmpty);

      final again = chatFor();
      await again.loadConversations();
      expect(again.scheduledFor(bob).single.content, 'later');

      expect(await again.sendDueScheduled(now: at.add(const Duration(seconds: 1))), 1);
      expect(again.scheduledFor(bob), isEmpty);
      expect(again.conversations[bob]!.single.content, 'later');

      await again.scheduleMessage(bob, 'never', at);
      await again.cancelScheduled(again.scheduledFor(bob).single.id);
      expect(again.scheduledFor(bob), isEmpty);
    });
  });

  group('vanish mode', () {
    test('is five minutes, and off puts back what the chat had', () async {
      final chat = chatFor();
      await chat.loadConversations();
      await chat.setDisappearing(bob, const Duration(days: 1));
      await chat.setVanish(bob, true);
      expect(chat.isVanish(bob), isTrue);
      expect(chat.disappearAfter(bob), ChatService.vanishAfter);
      await chat.setVanish(bob, false);
      expect(chat.isVanish(bob), isFalse);
      expect(chat.disappearAfter(bob), const Duration(days: 1));

      await chat.setVanish(bob, true);
      await chat.setDisappearing(bob, const Duration(hours: 1));
      expect(chat.isVanish(bob), isFalse, reason: 'another setting is not vanish mode');
    });
  });

  group('ignored chats', () {
    test('send no typing or read receipts, and raise no notification', () async {
      final library = LibraryService();
      await library.load();
      final chat = chatFor();
      chat.isIgnored = library.isChatIgnored;
      await library.toggleIgnoreChat(bob);
      expect(library.isChatIgnored(bob), isTrue);
      // Neither call throws nor seals anything: both return before sealing.
      await chat.notifyTyping(bob);
      await chat.markRead(bob);

      final sink = _Sink();
      final notifications = NotificationService(sink: sink);
      await notifications.load();
      notifications.isQuiet = library.isChatIgnored;
      AppLifecycle.foreground = false;
      final event = InboundEvent(
          kind: InboundKind.chat, id: 'c1', title: 'Bob', body: 'hi', route: '/chat/$bob', thread: 'chat:$bob', from: bob);
      expect(await notifications.handle(event), isFalse);
      await library.toggleIgnoreChat(bob);
      expect(await notifications.handle(event), isTrue);
    });
  });

  group('chat look', () {
    test('theme, nickname and emoji are local and persist', () async {
      final library = LibraryService();
      await library.load();
      expect(library.chatTheme('k'), 'default');
      expect(library.chatNickname('k'), isNull);
      expect(library.chatEmoji('k'), '🙌');
      await library.setChatLook('k', theme: 'ocean', nickname: ' Bobby ', emoji: '🔥');
      final again = LibraryService();
      await again.load();
      expect(again.chatTheme('k'), 'ocean');
      expect(again.chatNickname('k'), 'Bobby');
      expect(again.chatEmoji('k'), '🔥');
      await again.setChatLook('k', theme: 'default', nickname: '', emoji: '👍');
      expect(again.chatTheme('k'), 'default');
      expect(again.chatNickname('k'), isNull);
      expect(SecureStore.sensitivePrefixes, containsAll(['spheres_chat_looks_v1', 'spheres_scheduled_messages_v1']));
    });
  });

  group('notes', () {
    test('last a day, travel only while they last, and clear on the other side', () async {
      final profile = UserProfile(
        publicKey: 'me', displayName: 'Fai', bio: '', updatedAt: DateTime(2026, 10, 11),
        note: 'Off hiking', noteUntil: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(UserProfile.fromJson(profile.toJson()).note, 'Off hiking');
      final sent = ProfileSharing.payloadFor(profile: profile, peer: 'p', sharedSpheres: const {});
      expect((sent['note'] as Map)['text'], 'Off hiking');
      final stale = profile.copyWith(noteUntil: DateTime.now().subtract(const Duration(minutes: 1)));
      expect(ProfileSharing.payloadFor(profile: stale, peer: 'p', sharedSpheres: const {}).containsKey('note'), isFalse);
      final onlyMe = profile.copyWith(audience: {ProfileField.note: FieldAudience.me});
      expect(ProfileSharing.payloadFor(profile: onlyMe, peer: 'p', sharedSpheres: const {}).containsKey('note'), isFalse);

      final c = Contact.fromJson({'publicKey': 'k', 'displayName': 'Bo', 'addedAt': DateTime(2026).toIso8601String(),
          'note': 'x', 'noteUntil': DateTime.now().add(const Duration(hours: 1)).toIso8601String()});
      expect(c.activeNote, 'x');
      expect(c.copyWith(clearNote: true).activeNote, '');

      final identity = IdentityService();
      await identity.createIdentity('Fai');
      await identity.setNote('  Back on Monday  ');
      expect(identity.currentIdentity!.activeNote, 'Back on Monday');
      expect(await identity.expireNote(), isFalse, reason: 'still today');
      await identity.setNote('');
      expect(identity.currentIdentity!.note, '');
    });
  });

  group('bubbles', () {
    test('a direct message tries the bubble first and falls back to the notification', () async {
      final sink = _Sink();
      final n = NotificationService(sink: sink);
      await n.load();
      AppLifecycle.foreground = false;
      final bubbled = <String>[];
      n.bubble = (event, body) async {
        bubbled.add(body);
        return body == 'bubble me';
      };
      InboundEvent ev(String id, String body) => InboundEvent(
          kind: InboundKind.chat, id: id, title: 'Bob', body: body, route: '/chat/$bob', thread: 'chat:$bob', from: bob);
      expect(await n.handle(ev('1', 'bubble me')), isTrue);
      expect(sink.shown, isEmpty, reason: 'the bubble took it');
      expect(await n.handle(ev('2', 'plain')), isTrue);
      expect(sink.shown, ['plain']);
      n.bubble = (_, __) async => throw StateError('no platform');
      expect(await n.handle(ev('3', 'after a throw')), isTrue);
      expect(sink.shown.last, 'after a throw');
      // A post never bubbles.
      bubbled.clear();
      await n.handle(InboundEvent(kind: InboundKind.post, id: 'p', title: 'T', body: 'post', route: '/post/1', thread: 't'));
      expect(bubbled, isEmpty);
    });
  });
}
