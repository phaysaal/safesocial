import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/blob.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/blob_service.dart';
import 'package:spheres_app/services/chat_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/media_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Protected media on the message path. What is pinned: the sender's inline
/// thumbnail is a smear a few pixels wide; a protected post or message that
/// arrives is left as its blob reference and nothing is written to the media
/// cache; a protected post cannot be reshared from the composer and a reshare
/// of one is dropped on receipt; a protected message cannot be forwarded.
class _FakeRelay {
  final Map<String, String> chunks = {};
  int gets = 0;
  Future<http.Response> handle(
      String method, Uri url, Map<String, String> headers, List<int>? body) async {
    final key = '${url.pathSegments[1]}/${url.pathSegments[2]}';
    if (method == 'PUT') {
      chunks[key] = utf8.decode(body!);
      return http.Response('OK', 200);
    }
    gets++;
    final chunk = chunks[key];
    return chunk == null ? http.Response('', 404) : http.Response(chunk, 200);
  }
}

/// The documents directory, so the test can look inside the media cache.
class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String root;
  _FakePaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

void main() {
  late _FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    relay = _FakeRelay();
    BlobService.transportOverride = relay.handle;
    tmp = await Directory.systemTemp.createTemp('spheres_protected_');
    PathProviderPlatform.instance = _FakePaths(tmp.path);
  });

  tearDown(() async {
    BlobService.transportOverride = null;
    await tmp.delete(recursive: true);
  });

  Future<String> picture() async {
    final image = img.Image(width: 640, height: 480);
    img.fill(image, color: img.ColorRgb8(200, 30, 30));
    img.fillRect(image, x1: 0, y1: 0, x2: 320, y2: 480, color: img.ColorRgb8(30, 30, 200));
    final f = File('${tmp.path}/pic.jpg');
    await f.writeAsBytes(img.encodeJpg(image));
    return f.path;
  }

  Directory cache() => Directory('${tmp.path}/media');

  test('a protected upload carries a thumbnail a few pixels wide, a plain one does not',
      () async {
    final path = await picture();
    final plain = BlobRef.tryDecode((await MediaService.prepareForRelay(path))!)!;
    final guarded =
        BlobRef.tryDecode((await MediaService.prepareForRelay(path, protected: true))!)!;
    img.Image thumb(BlobRef r) => img.decodeImage(base64Decode(r.thumbnail!.split(',').last))!;
    expect(thumb(plain).width, 320);
    expect(thumb(guarded).width, MediaService.protectedThumbSide);
    expect(guarded.length, plain.length, reason: 'the picture itself is the same');
  });

  group('a protected post', () {
    late String alice, aliceSecret, bob, bobSecret, carol;
    late SphereService spheres;
    late FeedService feed;
    late Sphere sphere;

    setUp(() async {
      final a = ed.generateKey();
      final b = ed.generateKey();
      alice = hex.encode(a.publicKey.bytes);
      aliceSecret = hex.encode(a.privateKey.bytes);
      bob = hex.encode(b.publicKey.bytes);
      bobSecret = hex.encode(b.privateKey.bytes);
      carol = hex.encode(ed.generateKey().publicKey.bytes);
      spheres = SphereService();
      spheres.configure(
          sessions: SessionManager(),
          identityKey: alice,
          identitySecret: aliceSecret,
          resolveExchangeKey: (_) => null);
      sphere = await spheres.create(
          name: 'Family', kind: SphereKind.group, initialMembers: [bob, carol]);
      feed = FeedService();
      feed.initSync(alice, aliceSecret, const []);
      feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
      feed.membersOf =
          (id) => spheres.sphere(id)?.members.map((m) => m.identityKey).toList() ?? [];
    });

    Post signed(Post p, String secret) {
      final sig = ed.sign(
          ed.PrivateKey(hex.decode(secret)), Uint8List.fromList(p.signedCore().codeUnits));
      return p.copyWith(authorSig: hex.encode(sig));
    }

    Future<Post> bobsProtectedPost(String id) async {
      final ref = await MediaService.prepareForRelay(await picture(), protected: true);
      return signed(
          Post(
            id: id,
            authorId: bob,
            authorName: 'Bob',
            content: 'for your eyes',
            createdAt: DateTime(2026, 10, 12),
            sphereId: sphere.id,
            mediaRefs: [ref!],
            payload: const {'protected': {'wm': true}},
            allowReshare: false,
          ),
          bobSecret);
    }

    test('arrives as its reference and nothing lands in the media cache', () async {
      final post = await bobsProtectedPost('p1');
      final gets = relay.gets;
      await feed.applyFeedJson(
          authorId: bob, sphereId: sphere.id, json: {'type': 'post', 'post': post.toJson()});
      final held = feed.posts.singleWhere((p) => p.id == 'p1');
      expect(held.isProtected, isTrue);
      expect(held.protection!.watermark, isTrue);
      expect(BlobRef.looksLikeRef(held.mediaRefs.single), isTrue,
          reason: 'left for the viewer to decrypt in memory');
      expect(relay.gets, gets, reason: 'not even fetched at receipt');
      expect(cache().existsSync() && cache().listSync().isNotEmpty, isFalse);

      // The same post without the flag is fetched and written, which is what
      // makes the line above a test of the flag and not of the fake.
      // copyWith keeps a payload when handed null, so build the plain one.
      final plain = signed(
          Post(
            id: 'p2',
            authorId: bob,
            content: post.content,
            createdAt: post.createdAt,
            sphereId: sphere.id,
            mediaRefs: post.mediaRefs,
          ),
          bobSecret);
      await feed.applyFeedJson(
          authorId: bob, sphereId: sphere.id, json: {'type': 'post', 'post': plain.toJson()});
      expect(relay.gets, greaterThan(gets));
      expect(cache().listSync(), isNotEmpty);
      expect(feed.posts.singleWhere((p) => p.id == 'p2').mediaRefs.single, startsWith(tmp.path));
    });

    test('cannot be reshared, and a reshare of one is dropped on receipt', () async {
      final post = await bobsProtectedPost('p1');
      await feed.applyFeedJson(
          authorId: bob, sphereId: sphere.id, json: {'type': 'post', 'post': post.toJson()});
      final second =
          await spheres.create(name: 'Work', kind: SphereKind.group, initialMembers: [carol]);
      await expectLater(feed.resharePost('p1', targets: {second.id}),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Protected'))));

      // Carol's device says yes to resharing (the flag rides outside the
      // signed core, so she can) and the protection is still honoured here.
      final permissive = signed(post.copyWith(allowReshare: true), bobSecret);
      final reshare = Post(
        id: 'r1',
        authorId: carol,
        content: '',
        createdAt: DateTime(2026, 10, 12),
        sphereId: sphere.id,
        kind: 'reshare',
        payload: {'original': permissive.toJson()},
      );
      expect(FeedService.reshareAllowed(reshare), isFalse);
      await feed.applyFeedJson(
          authorId: carol, sphereId: sphere.id, json: {'type': 'post', 'post': reshare.toJson()});
      expect(feed.posts.where((p) => p.id == 'r1'), isEmpty);
    });
  });

  group('a protected message', () {
    test('is sent with its flag and refused by forward', () async {
      final a = ed.generateKey();
      final alice = hex.encode(a.publicKey.bytes);
      final aliceSecret = hex.encode(a.privateKey.bytes);
      final bob = hex.encode(ed.generateKey().publicKey.bytes);
      final sessions = SessionManager();
      await sessions.configure(
          keyExchangeKeyPair: await SpheresCrypto.newKeyExchangeKeyPair(),
          identityKey: alice,
          identitySecret: aliceSecret);
      final bobPair = await SpheresCrypto.newKeyExchangeKeyPair();
      final bobExchange = hex.encode((await bobPair.extractPublicKey()).bytes);
      final chat = ChatService();
      chat.setMyInfo(alice, aliceSecret,
          sessions: sessions, resolveExchangeKey: (k) => k == bob ? bobExchange : null);

      final sent = await chat.sendMessage(bob, '[Image]',
          mediaRefs: [await picture()], payload: const {'protected': {}});
      expect(sent.isProtected, isTrue);
      expect(relay.chunks, isNotEmpty, reason: 'the picture went up as a blob');

      final held = Message(
          id: 'm1',
          senderId: bob,
          recipientId: alice,
          content: '[Image]',
          timestamp: DateTime(2026, 10, 12),
          mediaRefs: const ['spheres-blob:x'],
          payload: const {'protected': {}});
      expect(() => chat.forwardMessage(bob, held), throwsA(isA<StateError>()));
    });
  });
}
