import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
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
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/blob_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/media_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// A picture that waits for the people in it. Alice posts a photo tagging
/// Bob and Carol and asks first. What is pinned: the wire post carries no
/// key, only boxes for Bob and Carol; Dave, a member who is not tagged,
/// holds nothing that opens the blob and nothing lands in his cache; Bob can
/// see it at once and is asked for his yes; after Bob's release Dave is
/// still waiting for Carol; after Carol's he has the key and the file; a
/// release from someone not tagged is dropped; a release that arrives
/// before its post is applied when the post comes.
class _FakeRelay {
  final Map<String, String> chunks = {};
  Future<http.Response> handle(
      String method, Uri url, Map<String, String> headers, List<int>? body) async {
    final key = '${url.pathSegments[1]}/${url.pathSegments[2]}';
    if (method == 'PUT') {
      chunks[key] = utf8.decode(body!);
      return http.Response('OK', 200);
    }
    final chunk = chunks[key];
    return chunk == null ? http.Response('', 404) : http.Response(chunk, 200);
  }
}

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String root;
  _FakePaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _Person {
  final String id, secret, x;
  final SimpleKeyPair pair;
  late final SessionManager sessions;
  late final SphereService spheres;
  late final FeedService feed;
  _Person(this.id, this.secret, this.x, this.pair);
}

void main() {
  const sphereId = '3333333333333333333333333333333333333333333333333333333333333333';
  late Directory tmp;
  late _Person alice, bob, carol, dave, erin;

  Future<_Person> person() async {
    final k = ed.generateKey();
    final pair = await SpheresCrypto.newKeyExchangeKeyPair();
    return _Person(hex.encode(k.publicKey.bytes), hex.encode(k.privateKey.bytes),
        hex.encode((await pair.extractPublicKey()).bytes), pair);
  }

  SphereMember member(_Person p, SphereRole role) => SphereMember(
      identityKey: p.id, role: role, joinedAt: DateTime(2026), invitedBy: alice.id,
      keyExchangePublicKey: p.x);

  String signedCreate() {
    final op = MembershipOp(
      sphereId: sphereId,
      epoch: 1,
      op: MembershipOp.opCreate,
      target: '',
      by: alice.id,
      timestampMs: DateTime(2026, 8, 1).millisecondsSinceEpoch,
      members: [
        member(alice, SphereRole.owner),
        member(bob, SphereRole.member),
        member(carol, SphereRole.member),
        member(dave, SphereRole.member),
        member(erin, SphereRole.member),
      ],
      name: 'Crew',
      kind: SphereKind.group,
    );
    return jsonEncode({
      'op': op.toJson(),
      'signature': hex.encode(ed.sign(ed.PrivateKey(hex.decode(alice.secret)), op.signedBytes())),
    });
  }

  /// A device that knows nobody: every exchange key comes from the member list.
  Future<void> device(_Person p) async {
    p.sessions = SessionManager();
    await p.sessions.configure(keyExchangeKeyPair: p.pair, identityKey: p.id, identitySecret: p.secret);
    p.spheres = SphereService();
    p.spheres.configure(
        sessions: p.sessions,
        identityKey: p.id,
        identitySecret: p.secret,
        resolveExchangeKey: (_) => null,
        myExchangeKey: p.x);
    await p.spheres.handleIncomingOp(alice.id, signedCreate());
    // An unknown sphere is an invitation on every device, the creator's included.
    await p.spheres.acceptInvite(sphereId);
    p.feed = FeedService();
    p.feed.initSync(p.id, p.secret, const []);
    p.feed.attachCrypto(p.sessions, (_) => null, spheres: p.spheres);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    BlobService.transportOverride = _FakeRelay().handle;
    tmp = await Directory.systemTemp.createTemp('spheres_consent_');
    PathProviderPlatform.instance = _FakePaths(tmp.path);
    alice = await person();
    bob = await person();
    carol = await person();
    dave = await person();
    erin = await person();
    for (final p in [alice, bob, carol, dave]) {
      await device(p);
    }
  });

  tearDown(() async {
    BlobService.transportOverride = null;
    await tmp.delete(recursive: true);
  });

  Future<String> picture() async {
    final image = img.Image(width: 320, height: 240);
    img.fill(image, color: img.ColorRgb8(30, 160, 60));
    final f = File('${tmp.path}/pic.jpg');
    await f.writeAsBytes(img.encodeJpg(image));
    return f.path;
  }

  Post signed(Post p, _Person by) {
    final sig = ed.sign(ed.PrivateKey(hex.decode(by.secret)), Uint8List.fromList(p.signedCore().codeUnits));
    return p.copyWith(authorSig: hex.encode(sig));
  }

  Future<void> arrives(_Person at, _Person from, Map<String, dynamic> json) =>
      at.feed.applyFeedJson(authorId: from.id, sphereId: sphereId, json: json);

  int cached() => Directory('${tmp.path}/media').existsSync()
      ? Directory('${tmp.path}/media').listSync().length
      : 0;

  test('the whole way round: locked for Dave until Bob and Carol both say yes', () async {
    final ref = await MediaService.prepareForRelay(await picture());
    final plain = signed(
        Post(
          id: 'p1',
          authorId: alice.id,
          authorName: 'Alice',
          content: 'us three',
          createdAt: DateTime(2026, 10, 12),
          sphereId: sphereId,
          mediaRefs: [ref!],
          payload: {'tags': [bob.id, carol.id], 'consent': true},
        ),
        alice);
    final wire = await alice.feed.lockMedia(plain, [bob.id, carol.id]);

    final locked = BlobRef.tryDecode(wire.mediaRefs.single)!;
    expect(locked.isLocked, isTrue, reason: 'no key travels with the post');
    expect(locked.address, BlobRef.tryDecode(ref)!.address);
    final preview = img.decodeImage(base64Decode(locked.thumbnail!.split(',').last))!;
    expect(preview.width, MediaService.protectedThumbSide,
        reason: 'the preview that travels with a locked picture is a smear');
    final lock = wire.lock!;
    expect(lock[0]!.tags, {bob.id, carol.id});
    expect(lock[0]!.keys.containsKey(dave.id), isFalse);
    expect(await BlobService().download(locked), isNull, reason: 'a locked reference opens nothing');

    final json = {'type': 'post', 'post': wire.toJson()};
    final before = cached();
    await arrives(dave, alice, json);
    final davesCopy = dave.feed.posts.single;
    expect(BlobRef.tryDecode(davesCopy.mediaRefs.single)!.isLocked, isTrue);
    expect(cached(), before, reason: 'nothing to fetch, nothing written');
    expect(dave.feed.awaitsMyRelease(davesCopy), isFalse);

    await arrives(bob, alice, json);
    final bobsCopy = bob.feed.posts.single;
    expect(bobsCopy.mediaRefs.single, startsWith(tmp.path),
        reason: 'Bob was sealed the key, so he sees what he is asked about');
    expect(bob.feed.awaitsMyRelease(bobsCopy), isTrue);
    await arrives(carol, alice, json);

    // Bob says yes. His own copy records it; Dave, told, still waits for Carol.
    await bob.feed.releaseMedia('p1');
    final bobsRelease = bob.feed.posts.single.lock![0]!.released[bob.id]!;
    expect(bob.feed.awaitsMyRelease(bob.feed.posts.single), isFalse);
    await arrives(dave, bob, {'type': 'media_release', 'post_id': 'p1', 'index': 0, 'share': bobsRelease});
    expect(dave.feed.posts.single.lock![0]!.waiting, {carol.id});
    expect(BlobRef.tryDecode(dave.feed.posts.single.mediaRefs.single)!.isLocked, isTrue);

    // Dave forges a release of his own: not tagged, dropped.
    await arrives(dave, dave, {'type': 'media_release', 'post_id': 'p1', 'index': 0, 'share': bobsRelease});
    expect(dave.feed.posts.single.lock![0]!.waiting, {carol.id});

    // Carol says yes: Dave now holds every share, joins the key and fetches.
    await carol.feed.releaseMedia('p1');
    final carolsRelease = carol.feed.posts.single.lock![0]!.released[carol.id]!;
    await arrives(dave, carol, {'type': 'media_release', 'post_id': 'p1', 'index': 0, 'share': carolsRelease});
    final opened = dave.feed.posts.single;
    expect(opened.lock![0]!.complete, isTrue);
    expect(opened.mediaRefs.single, startsWith(tmp.path), reason: 'fetched and on disk');
    expect(cached(), greaterThan(before));
    expect(await File(opened.mediaRefs.single).length(), BlobRef.tryDecode(ref)!.length);

    // A member whose device gets the releases before the post is fine too.
    await device(erin);
    await arrives(erin, bob, {'type': 'media_release', 'post_id': 'p1', 'index': 0, 'share': bobsRelease});
    await arrives(erin, carol, {'type': 'media_release', 'post_id': 'p1', 'index': 0, 'share': carolsRelease});
    await arrives(erin, alice, json);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(erin.feed.posts.single.lock![0]!.complete, isTrue);
    expect(erin.feed.posts.single.mediaRefs.single, startsWith(tmp.path));
  });

  test('asking first is refused up front when a tagged person has no key', () async {
    final stranger = hex.encode(ed.generateKey().publicKey.bytes);
    await expectLater(
      alice.feed.createPost('x',
          sphereId: sphereId,
          audienceMembers: const [],
          mediaRefs: [await picture()],
          payload: {'tags': [stranger], 'consent': true}),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('No key'))),
    );
    expect(alice.feed.posts, isEmpty, reason: 'nothing stored as sent');
    await expectLater(
      alice.feed.createPost('x',
          sphereId: sphereId, audienceMembers: const [], payload: {'tags': [bob.id], 'consent': true}),
      throwsA(isA<StateError>()),
      reason: 'no picture to lock',
    );
  });

  test('an author asking first stores their own copy with the lock and local files', () async {
    await alice.feed.createPost('us',
        sphereId: sphereId,
        audienceMembers: const [],
        mediaRefs: [await picture()],
        payload: {'tags': [bob.id, alice.id], 'consent': true});
    final mine = alice.feed.posts.single;
    expect(mine.mediaRefs.single, startsWith(tmp.path), reason: 'the author keeps the file');
    expect(mine.lock![0]!.tags, {bob.id}, reason: 'tagging yourself asks nobody');
    expect(alice.feed.awaitsMyRelease(mine), isFalse);
  });
}
