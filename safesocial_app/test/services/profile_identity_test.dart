import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/profile_about.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/identity_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Our side and theirs. Ours: a temporary picture goes back to the old one
/// when its time is up, and an audience set back to "all contacts" leaves no
/// trace. Theirs: a profile message is their whole view of themselves for
/// us, so a field it no longer carries is gone, while a malformed one does
/// not wipe what was there.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  group('our profile', () {
    test('a temporary picture comes back to the earlier one when it runs out',
        () async {
      final identity = IdentityService();
      await identity.createIdentity('Fai');
      final changes = <String?>[];
      identity.onProfileChanged = (p) async => changes.add(p.avatarRef);

      await identity.updateAvatar('/old.jpg');
      await identity.updateAvatar('/party.jpg',
          temporaryFor: const Duration(milliseconds: 1));
      expect(identity.currentIdentity!.avatarIsTemporary, isTrue);
      expect(identity.currentIdentity!.avatarRef, '/party.jpg');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await identity.expireTemporaryAvatar(), isTrue);
      expect(identity.currentIdentity!.avatarRef, '/old.jpg');
      expect(identity.currentIdentity!.avatarIsTemporary, isFalse);
      expect(changes.last, '/old.jpg', reason: 'contacts are told');

      expect(await identity.expireTemporaryAvatar(), isFalse,
          reason: 'nothing temporary left');
    });

    test('a temporary picture with no earlier one goes back to none', () async {
      final identity = IdentityService();
      await identity.createIdentity('Fai');
      await identity.updateAvatar('/party.jpg',
          temporaryFor: const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await identity.expireTemporaryAvatar();
      expect(identity.currentIdentity!.avatarRef, isNull);
    });

    test('a temporary picture over a temporary picture restores the original',
        () async {
      final identity = IdentityService();
      await identity.createIdentity('Fai');
      await identity.updateAvatar('/original.jpg');
      await identity.updateAvatar('/first.jpg', temporaryFor: const Duration(days: 1));
      await identity.updateAvatar('/second.jpg',
          temporaryFor: const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await identity.expireTemporaryAvatar();
      expect(identity.currentIdentity!.avatarRef, '/original.jpg');
    });

    test('an audience of all contacts is the default and leaves no entry', () async {
      final identity = IdentityService();
      await identity.createIdentity('Fai');
      await identity.setFieldAudience(ProfileField.work, FieldAudience.me);
      expect(identity.currentIdentity!.audience[ProfileField.work], FieldAudience.me);
      await identity.setFieldAudience(ProfileField.work, FieldAudience.contacts);
      expect(identity.currentIdentity!.audience.containsKey(ProfileField.work), isFalse);
    });

    test('the legacy contact can be named and unnamed', () async {
      final identity = IdentityService();
      await identity.createIdentity('Fai');
      await identity.setLegacyContact('sis');
      expect(identity.currentIdentity!.legacyContact, 'sis');
      await identity.setLegacyContact(null);
      expect(identity.currentIdentity!.legacyContact, isNull);
    });
  });

  group('our other devices', () {
    test('a newer profile from another of our devices is adopted without a broadcast',
        () async {
      final here = IdentityService();
      await here.createIdentity('Fai');
      var broadcasts = 0;
      here.onProfileChanged = (_) async => broadcasts++;

      final there = IdentityService();
      await there.createIdentity('Fai');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await there.updateProfile(bio: 'from the tablet');
      await there.updateAbout(const ProfileAbout(pronouns: 'he/him'));
      await there.setFieldAudience(ProfileField.work, FieldAudience.me);

      await here.adoptFromOwnDevice(
        there.profileForOwnDevices(avatarRef: 'blob:a'),
        materialise: (ref) async => '/local/$ref',
      );
      final p = here.currentIdentity!;
      expect(p.bio, 'from the tablet');
      expect(p.about.pronouns, 'he/him');
      expect(p.audience[ProfileField.work], FieldAudience.me);
      expect(p.avatarRef, '/local/blob:a');
      expect(p.publicKey, isNot(there.publicKey), reason: 'our key stays ours');
      expect(broadcasts, 0);
    });

    test('an older copy is ignored', () async {
      final here = IdentityService();
      await here.createIdentity('Fai');
      final stale = IdentityService();
      await stale.createIdentity('Fai');
      await stale.updateProfile(bio: 'old');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await here.updateProfile(bio: 'new');
      await here.adoptFromOwnDevice(stale.profileForOwnDevices());
      expect(here.currentIdentity!.bio, 'new');
    });

    test('a sibling with the same words but no picture file takes the picture', () async {
      // Found on hardware: a tablet linked from the phone's backup held the
      // profile with the phone's picture path, which is nothing on the
      // tablet, and every resend from the phone was "not newer" and dropped.
      final phone = IdentityService();
      await phone.createIdentity('Fai');
      await phone.updateAvatar('/phone/me.jpg');
      final tablet = IdentityService();
      await tablet.createIdentity('Fai');
      await tablet.adoptFromOwnDevice(
        {'own': phone.currentIdentity!.toJson()..remove('avatarRef')},
      );
      // The restore: same words, same time, a dead path.
      await tablet.updateAvatar('/phone/me.jpg');
      final sameWords = phone.currentIdentity!.copyWith(updatedAt: tablet.currentIdentity!.updatedAt);
      IdentityService.fileExists = (path) => path.startsWith('/tablet/');

      try {
        final fetched = <String>[];
        await tablet.adoptFromOwnDevice(
          {'own': sameWords.toJson()..remove('avatarRef'), 'avatar': 'blob:pic'},
          materialise: (ref) async {
            fetched.add(ref);
            return '/tablet/me.jpg';
          },
        );
        expect(fetched, ['blob:pic']);
        expect(tablet.currentIdentity!.avatarRef, '/tablet/me.jpg');

        // Held now, so the same message again fetches nothing.
        await tablet.adoptFromOwnDevice(
          {'own': sameWords.toJson()..remove('avatarRef'), 'avatar': 'blob:pic'},
          materialise: (ref) async {
            fetched.add(ref);
            return '/tablet/again.jpg';
          },
        );
        expect(fetched, ['blob:pic']);
        expect(tablet.currentIdentity!.avatarRef, '/tablet/me.jpg');
      } finally {
        IdentityService.fileExists = (path) => File(path).existsSync();
      }
    });

    test('garbage from a device is ignored', () async {
      final here = IdentityService();
      await here.createIdentity('Fai');
      await here.adoptFromOwnDevice({'own': 'nope'});
      await here.adoptFromOwnDevice({'own': {'displayName': 7}});
      expect(here.currentIdentity!.displayName, 'Fai');
    });
  });

  group('a contact\'s profile', () {
    test('about, cover, featured and the legacy flag are taken in', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      contacts.materialiseMedia = (ref) async => '/local/$ref';
      await contacts.addContact('bob', 'Bob',
          keyExchangePublicKey: 'aa' * 32, announce: false);

      await contacts.applyProfile('bob', {
        'name': 'Bob',
        'bio': 'hi there',
        'birthday': '01-02',
        'cover': 'blob:c',
        'featured': ['blob:1', 'blob:2'],
        'about': {'work': 'Baker', 'pronouns': 'he/him'},
        'legacy': true,
      });
      final c = contacts.getContact('bob')!;
      expect(c.bio, 'hi there');
      expect(c.birthday, '01-02');
      expect(c.coverRef, '/local/blob:c');
      expect(c.featuredRefs, ['/local/blob:1', '/local/blob:2']);
      expect(c.about.work, 'Baker');
      expect(c.namedMeLegacy, isTrue);
    });

    test('a field the next message leaves out is withdrawn', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      contacts.materialiseMedia = (ref) async => '/local/$ref';
      await contacts.addContact('bob', 'Bob',
          keyExchangePublicKey: 'aa' * 32, announce: false);
      await contacts.applyProfile('bob', {
        'name': 'Bob',
        'birthday': '01-02',
        'cover': 'blob:c',
        'about': {'work': 'Baker'},
        'legacy': true,
      });

      // Bob moved us out of the audience for all of it.
      await contacts.applyProfile('bob', {'name': 'Bob'});
      final c = contacts.getContact('bob')!;
      expect(c.birthday, isNull);
      expect(c.coverRef, isNull);
      expect(c.about.isEmpty, isTrue);
      expect(c.namedMeLegacy, isFalse);
    });

    test('a malformed field does not wipe the last good one', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      await contacts.addContact('bob', 'Bob',
          keyExchangePublicKey: 'aa' * 32, announce: false);
      await contacts.applyProfile('bob', {'name': 'Bob', 'birthday': '01-02'});
      await contacts.applyProfile('bob', {'name': 'Bob', 'birthday': 'soon'});
      expect(contacts.getContact('bob')!.birthday, '01-02');
    });
  });
}
