import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/envelope.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/album_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Album items went out on a relay client of their own, addressed by member —
/// but that client only ever held a connection keyed by album, so the lookup
/// found nothing and the send was discarded. Sharing an album item did nothing
/// at all, in either direction.
///
/// They now travel the per-member feed channels like everything else addressed
/// to a sphere: same durable queue, same archive, so one is not lost because
/// somebody was briefly away and a peer can hand it over later.
void main() {
  late String alice, aliceSecret, bob, carol;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();

    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(ed.generateKey().publicKey.bytes);
    carol = hex.encode(ed.generateKey().publicKey.bytes);
  });

  Future<(AlbumService, SphereService, Sphere, List<String>)> setUpAlbum({
    bool attachTransport = true,
  }) async {
    final spheres = SphereService();
    spheres.configure(
      sessions: SessionManager(),
      identityKey: alice,
      identitySecret: aliceSecret,
      resolveExchangeKey: (_) => null,
    );
    final sphere = await spheres.create(
      name: 'Holiday',
      kind: SphereKind.group,
      initialMembers: [bob, carol],
    );

    final sentTo = <String>[];
    final albums = AlbumService()..attachSpheres(spheres);
    albums.initSync(alice, aliceSecret);
    if (attachTransport) {
      albums.queueForMember = ({
        required String id,
        required String member,
        required String sealed,
      }) async {
        sentTo.add(member);
      };
    }
    return (albums, spheres, sphere, sentTo);
  }

  test('an album item reaches every other member', () async {
    final (albums, _, sphere, sentTo) = await setUpAlbum();
    await albums.createAlbum('Holiday', '', sphere.id);
    final album = albums.albums.single;

    await albums.addMediaToAlbum(album.dhtKey, 'not-a-real-path', 'image');

    // Previously nobody: the send addressed a connection that never existed.
    expect(sentTo.toSet(), {bob, carol});
  });

  test('it does not send a copy to ourselves', () async {
    final (albums, _, sphere, sentTo) = await setUpAlbum();
    await albums.createAlbum('Holiday', '', sphere.id);

    await albums.addMediaToAlbum(
        albums.albums.single.dhtKey, 'not-a-real-path', 'image');

    expect(sentTo, isNot(contains(alice)));
  });

  test('what goes out is sealed to the album\'s sphere', () async {
    // Which is what lets a peer relay it later: the envelope names the sphere
    // and carries its author's signature.
    final spheres = SphereService();
    spheres.configure(
      sessions: SessionManager(),
      identityKey: alice,
      identitySecret: aliceSecret,
      resolveExchangeKey: (_) => null,
    );
    final sphere = await spheres.create(
        name: 'Holiday', kind: SphereKind.group, initialMembers: [bob]);

    final payloads = <String>[];
    final albums = AlbumService()..attachSpheres(spheres);
    albums.initSync(alice, aliceSecret);
    albums.queueForMember = ({
      required String id,
      required String member,
      required String sealed,
    }) async {
      payloads.add(sealed);
    };

    await albums.createAlbum('Holiday', '', sphere.id);
    await albums.addMediaToAlbum(
        albums.albums.single.dhtKey, 'not-a-real-path', 'image');

    final envelope = Envelope.decode(payloads.single);
    expect(envelope.sphereId, sphere.id);
    expect(envelope.from, alice);

    final opened = await spheres.openContent(payloads.single);
    expect(jsonDecode(opened.plaintext)['type'], 'album_add');
  });

  test('with no transport attached the item is kept, not silently dropped',
      () async {
    final (albums, _, sphere, _) = await setUpAlbum(attachTransport: false);
    await albums.createAlbum('Holiday', '', sphere.id);
    final album = albums.albums.single;

    await albums.addMediaToAlbum(album.dhtKey, 'not-a-real-path', 'image');

    // It is ours either way; what failed is telling anyone else.
    expect(albums.albums.single.items, hasLength(1));
  });

  test('an album for a sphere we have left is not shared', () async {
    final (albums, spheres, sphere, sentTo) = await setUpAlbum();
    await albums.createAlbum('Holiday', '', sphere.id);
    await spheres.leave(sphere.id);

    await albums.addMediaToAlbum(
        albums.albums.single.dhtKey, 'not-a-real-path', 'image');

    expect(sentTo, isEmpty);
  });
}
