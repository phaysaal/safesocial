import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/profile_about.dart';
import 'package:spheres_app/models/user_profile.dart';
import 'package:spheres_app/services/profile_sharing.dart';

/// What each contact is sent is the one place a profile's privacy is
/// decided. The name and the picture always go; everything else goes when
/// the contact is in the field's audience, judged by the spheres they share
/// with us; "only me" never goes; the legacy contact alone learns they are.
void main() {
  final profile = UserProfile(
    publicKey: 'me',
    displayName: 'Fai',
    bio: 'hello',
    updatedAt: DateTime(2026, 10, 11),
    birthday: '10-11',
    about: const ProfileAbout(
      pronouns: 'he/him',
      work: 'Researcher',
      city: 'Paris',
      quotes: 'secret',
    ),
    audience: {
      ProfileField.birthday: FieldAudience.spheres({'family'}),
      ProfileField.work: FieldAudience.spheres({'work', 'family'}),
      ProfileField.city: FieldAudience.me,
      ProfileField.quotes: FieldAudience.me,
      ProfileField.cover: FieldAudience.spheres({'family'}),
    },
    legacyContact: 'sis',
  );

  Map<String, dynamic> send(String peer, Set<String> shared) =>
      ProfileSharing.payloadFor(
        profile: profile,
        peer: peer,
        sharedSpheres: shared,
        avatarRef: 'blob:avatar',
        coverRef: 'blob:cover',
        featuredRefs: const ['blob:f1'],
      );

  test('a contact in no sphere gets the name, picture, bio and the open fields',
      () {
    final p = send('stranger', const {});
    expect(p['name'], 'Fai');
    expect(p['avatar'], 'blob:avatar');
    expect(p['bio'], 'hello');
    expect(p['featured'], ['blob:f1'], reason: 'featured defaults to all contacts');
    expect(p.containsKey('birthday'), isFalse);
    expect(p.containsKey('cover'), isFalse);
    expect(p.containsKey('legacy'), isFalse);
    final about = p['about'] as Map<String, dynamic>;
    expect(about['pronouns'], 'he/him');
    expect(about.containsKey('work'), isFalse);
    expect(about.containsKey('city'), isFalse, reason: 'only me');
    expect(about.containsKey('quotes'), isFalse, reason: 'only me');
  });

  test('a contact in the family sphere gets the family fields', () {
    final p = send('mum', {'family'});
    expect(p['birthday'], '10-11');
    expect(p['cover'], 'blob:cover');
    expect((p['about'] as Map)['work'], 'Researcher');
    expect((p['about'] as Map).containsKey('city'), isFalse, reason: 'only me stays home');
  });

  test('a colleague gets work but not the birthday', () {
    final p = send('colleague', {'work'});
    expect((p['about'] as Map)['work'], 'Researcher');
    expect(p.containsKey('birthday'), isFalse);
    expect(p.containsKey('cover'), isFalse);
  });

  test('only the legacy contact is told they are', () {
    expect(send('sis', const {})['legacy'], isTrue);
    expect(send('mum', {'family'}).containsKey('legacy'), isFalse);
  });

  test('nothing in the about at all means no about key', () {
    final bare = UserProfile(
        publicKey: 'me', displayName: 'Fai', bio: '', updatedAt: DateTime(2026));
    final p = ProfileSharing.payloadFor(
        profile: bare, peer: 'x', sharedSpheres: const {});
    expect(p.containsKey('about'), isFalse);
    expect(p['bio'], '');
  });

  test('visibleFields is the same judgement the payload uses', () {
    final f = ProfileSharing.visibleFields(profile, {'work'});
    expect(f, contains(ProfileField.work));
    expect(f, contains(ProfileField.pronouns));
    expect(f, isNot(contains(ProfileField.birthday)));
    expect(f, isNot(contains(ProfileField.city)));
  });
}
