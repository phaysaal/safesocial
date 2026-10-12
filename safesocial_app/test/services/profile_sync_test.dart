import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/profile_about.dart';
import 'package:spheres_app/services/identity_service.dart';
import 'package:spheres_app/services/profile_sync.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Found on hardware: a contact added after the picture was chosen never saw
/// it. The profile went out only at the moment of an edit, and only to
/// contacts with a chat entry, so the new contact held an initial until the
/// next edit, which could be never.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  const alice = 'a';
  const bob = 'b';

  ({ProfileSync sync, List<(String, Map<String, dynamic>)> sent, List<String> uploads, List<Map<String, dynamic>> own})
      build(IdentityService identity, List<String> peers, {Set<String> Function(String)? shared}) {
    final sent = <(String, Map<String, dynamic>)>[];
    final uploads = <String>[];
    final own = <Map<String, dynamic>>[];
    final sync = ProfileSync(
      profile: () => identity.currentIdentity,
      peers: () => peers,
      sharedSpheres: shared ?? (_) => {},
      restricted: (_) => false,
      upload: (local) async {
        uploads.add(local);
        return 'blob:${uploads.length}';
      },
      send: (peer, payload) async {
        sent.add((peer, payload));
        return true;
      },
      sendOwn: (e) async => own.add(e),
      everything: identity.profileForOwnDevices,
    );
    return (sync: sync, sent: sent, uploads: uploads, own: own);
  }

  test('restricting a contact makes their copy due again, and it is the narrow one', () async {
    // Seen with three phones: a restricted contact kept the fuller copy of
    // the profile until the next start, because nothing resent it.
    final identity = IdentityService();
    await identity.createIdentity('Fai');
    await identity.updateProfile(bio: 'Says things');
    final restricted = <String>{};
    final sent = <(String, Map<String, dynamic>)>[];
    final sync = ProfileSync(
      profile: () => identity.currentIdentity,
      peers: () => [alice],
      sharedSpheres: (_) => {},
      restricted: restricted.contains,
      upload: (local) async => 'blob',
      send: (peer, payload) async {
        sent.add((peer, payload));
        return true;
      },
      sendOwn: (_) async {},
      everything: identity.profileForOwnDevices,
    );
    await sync.sync(onlyChanged: false);
    expect(sent.single.$2['bio'], 'Says things');
    expect(await sync.sync(to: [alice]), isEmpty, reason: 'nothing changed');

    restricted.add(alice);
    expect(await sync.sync(to: [alice]), [alice]);
    expect(sent.last.$2.containsKey('bio'), isFalse, reason: 'name and picture only');

    restricted.remove(alice);
    expect(await sync.sync(to: [alice]), [alice], reason: 'released: the full cut again');
    expect(sent.last.$2['bio'], 'Says things');
  });

  test('a contact added after the picture was chosen is sent it', () async {
    final identity = IdentityService();
    await identity.createIdentity('Fai');
    await identity.updateAvatar('/me.jpg');
    final peers = <String>[alice];
    final s = build(identity, peers);

    // The edit went out, before Bob existed.
    await s.sync.sync(onlyChanged: false);
    expect(s.sent.map((e) => e.$1), [alice]);
    expect(s.sent.single.$2['avatar'], 'blob:1');
    expect(s.own, hasLength(1), reason: 'our other devices get the whole profile');

    // Bob is added: he alone gets it, and the blob is uploaded afresh.
    peers.add(bob);
    expect(await s.sync.sync(to: [bob]), [bob]);
    expect(s.sent.last.$1, bob);
    expect(s.sent.last.$2['avatar'], 'blob:2');
    expect(s.sent, hasLength(2), reason: 'Alice is not sent it again');
  });

  test('a device linked since the last send makes the whole profile due again', () async {
    final identity = IdentityService();
    await identity.createIdentity('Fai');
    await identity.updateAvatar('/me.jpg');
    final devices = <String>['phone'];
    final own = <Map<String, dynamic>>[];
    final sync = ProfileSync(
      profile: () => identity.currentIdentity,
      peers: () => const [],
      sharedSpheres: (_) => {},
      restricted: (_) => false,
      upload: (l) async => 'blob',
      send: (_, __) async => true,
      sendOwn: (e) async => own.add(e),
      everything: identity.profileForOwnDevices,
      ownDevices: () => devices,
    );
    await sync.sync(onlyChanged: false);
    await sync.sync();
    expect(own, hasLength(1));

    devices.add('tablet');
    await sync.sync();
    expect(own, hasLength(2), reason: 'the tablet holds our words but not our picture');
    expect(own.last['avatar'], 'blob');
    await sync.sync();
    expect(own, hasLength(2));
  });

  test('a start with everyone up to date sends nothing and uploads nothing', () async {
    final identity = IdentityService();
    await identity.createIdentity('Fai');
    await identity.updateAvatar('/me.jpg');
    final s = build(identity, [alice, bob]);
    await s.sync.sync(onlyChanged: false);
    s.sent.clear();
    s.uploads.clear();

    expect(await s.sync.sync(), isEmpty);
    expect(s.sent, isEmpty);
    expect(s.uploads, isEmpty, reason: 'nothing due, so no blob goes up');
  });

  test('what was sent survives a restart, and a failed send is retried', () async {
    final identity = IdentityService();
    await identity.createIdentity('Fai');
    await identity.updateAvatar('/me.jpg');
    var fail = true;
    final sent = <String>[];
    ProfileSync make() => ProfileSync(
          profile: () => identity.currentIdentity,
          peers: () => [alice, bob],
          sharedSpheres: (_) => {},
          restricted: (_) => false,
          upload: (l) async => 'blob',
          send: (peer, _) async {
            if (peer == bob && fail) return false;
            sent.add(peer);
            return true;
          },
          sendOwn: (_) async {},
          everything: identity.profileForOwnDevices,
        );

    expect(await make().sync(), [alice], reason: 'the relay did not take Bob\'s');
    fail = false;
    // A new process: Alice is remembered, Bob is owed.
    expect(await make().sync(), [bob]);
    expect(sent, [alice, bob]);
    expect(await make().sync(), isEmpty);
  });

  test('a contact who comes to share a sphere gets the wider cut; a removed one is forgotten', () async {
    final identity = IdentityService();
    await identity.createIdentity('Fai');
    await identity.updateProfile(bio: 'hello');
    // The bio is only for one sphere, which Alice is not in yet.
    await identity.setFieldAudience(ProfileField.bio, FieldAudience.spheres({'sphere-1'}));
    final shared = <String, Set<String>>{};
    final s = build(identity, [alice], shared: (p) => shared[p] ?? {});
    await s.sync.sync(onlyChanged: false);
    expect(s.sent.last.$2.containsKey('bio'), isFalse);
    expect(await s.sync.sync(), isEmpty);

    // She joins it: the next start sends her the wider cut.
    shared[alice] = {'sphere-1'};
    expect(await s.sync.sync(), [alice]);
    expect(s.sent.last.$2['bio'], 'hello');

    await s.sync.forget(alice);
    expect(s.sync.lastSentTo(alice), isNull);
    expect(await s.sync.sync(to: [alice]), [alice], reason: 'a re-added contact starts afresh');
  });
}
