import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/album.dart';
import 'package:spheres_app/models/look.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/album_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// A look on an album item: carried with the item, changed after by whoever
/// added it as a few numbers sealed to the sphere, honoured from nobody else.
void main() {
  late String alice, aliceSecret, bob;
  late SphereService spheres;
  late Sphere sphere;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(ed.generateKey().publicKey.bytes);
    spheres = SphereService()
      ..configure(sessions: SessionManager(), identityKey: alice, identitySecret: aliceSecret, resolveExchangeKey: (_) => null);
    sphere = await spheres.create(name: 'Holiday', kind: SphereKind.group, initialMembers: [bob]);
  });

  test('an item carries its look through JSON, and none when it has none', () {
    final item = AlbumItem(
        id: 'i1', authorId: alice, mediaRef: 'ref', type: 'image', addedAt: DateTime(2026, 10, 25),
        look: {'*': const Look(exposure: 0.4).toJson()});
    final back = AlbumItem.fromJson(jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>);
    expect(back.look, item.look);
    expect(Look.tryParse(back.look!['*'])!.exposure, 0.4);
    final plain = AlbumItem(id: 'i2', authorId: alice, mediaRef: 'ref', type: 'image', addedAt: DateTime(2026));
    expect(plain.toJson().containsKey('look'), isFalse);
    expect(plain.copyWith(look: {'*': {}}).copyWith(clearLook: true).look, isNull);
  });

  test('whoever added the item changes its look and a sealed album_look goes to the others; nobody else may', () async {
    final sent = <(String, String)>[];
    final albums = AlbumService()..attachSpheres(spheres);
    albums.initSync(alice, aliceSecret);
    albums.queueForMember = ({required String id, required String member, required String sealed}) async {
      sent.add((member, sealed));
    };
    await albums.createAlbum('Holiday', '', sphere.id);
    final albumId = albums.albums.single.dhtKey;
    // An item of Alice's, arriving the way items arrive, without the upload path.
    final item = AlbumItem(id: 'i1', authorId: alice, mediaRef: 'ref', type: 'image', addedAt: DateTime(2026));
    Future<String> addOf(String forAlbum) => spheres.sealContent(
        sphereId: sphere.id,
        type: 'album_add',
        plaintext: jsonEncode({'type': 'album_add', 'album_id': forAlbum, 'item': item.toJson()}));
    await albums.handleSealedItem(await addOf(albumId));
    expect(albums.albums.single.items.single.id, 'i1');

    final look = {'*': const Look(temperature: 0.3).toJson()};
    await albums.setItemLook(albumId, 'i1', look);
    expect(albums.albums.single.items.single.look, look);
    expect(sent.map((s) => s.$1), [bob]);
    final opened = await spheres.openContent(sent.single.$2);
    final json = jsonDecode(opened.plaintext) as Map<String, dynamic>;
    expect(json['type'], 'album_look');
    expect(json['look'], look);
    expect(json.containsKey('mediaRef'), isFalse, reason: 'numbers only, no picture');

    // Bob's view: the same album, the item from Alice; Alice's look lands, Bob's is dropped, null removes.
    final bobs = AlbumService()..attachSpheres(spheres);
    bobs.initSync(bob, 'secret');
    await bobs.createAlbum('Holiday', '', sphere.id);
    final bobsAlbumId = bobs.albums.single.dhtKey;
    await bobs.handleSealedItem(await addOf(bobsAlbumId));
    expect(bobs.albums.single.items.single.authorId, alice);
    bobs.applyLook(sphere.id, alice, {'album_id': bobsAlbumId, 'item_id': 'i1', 'look': look});
    expect(bobs.albums.single.items.single.look, look);
    bobs.applyLook(sphere.id, bob, {'album_id': bobsAlbumId, 'item_id': 'i1', 'look': null});
    expect(bobs.albums.single.items.single.look, look, reason: 'Bob did not add it');
    bobs.applyLook('another-sphere', alice, {'album_id': bobsAlbumId, 'item_id': 'i1', 'look': null});
    expect(bobs.albums.single.items.single.look, look, reason: 'sealed to the wrong sphere');
    bobs.applyLook(sphere.id, alice, {'album_id': bobsAlbumId, 'item_id': 'i1', 'look': null});
    expect(bobs.albums.single.items.single.look, isNull);

    await expectLater(bobs.setItemLook(bobsAlbumId, 'i1', look), throwsStateError);
  });
}
