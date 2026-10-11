import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/contact.dart';
import 'package:spheres_app/models/profile_about.dart';
import 'package:spheres_app/models/user_profile.dart';

/// The profile grew an "about" with an audience per field. What is pinned
/// here: a profile saved before any of it still reads and a plain one still
/// writes the same keys; what a contact sends is bounded and never throws;
/// an audience reads back as it was written and an unknown one means "only
/// me"; cutting a profile to a field set blanks exactly the rest.
void main() {
  final full = ProfileAbout(
    pronouns: 'they/them',
    nickname: 'Fai',
    pronunciation: 'FAY-sal',
    work: 'Researcher',
    education: 'Sorbonne',
    city: 'Paris',
    hometown: 'Dhaka',
    relationshipStatus: 'married',
    partner: const NamedPerson(key: 'k-partner', label: 'M', relation: 'partner'),
    family: const [NamedPerson(key: 'k-sis', label: 'S', relation: 'sister')],
    languages: const ['Bangla', 'English', 'French'],
    websites: const ['https://safeself.fr'],
    hobbies: const ['cycling'],
    quotes: 'Less, but better.',
    lifeEvents: const [LifeEvent(title: 'Moved to Paris', date: '2019-09')],
  );

  test('a full about survives a round trip', () {
    final back = ProfileAbout.fromJson(
        jsonDecode(jsonEncode(full.toJson())) as Map<String, dynamic>);
    expect(back, full);
  });

  test('an empty about writes nothing and reads as empty', () {
    expect(ProfileAbout.empty.toJson(), isEmpty);
    expect(ProfileAbout.fromJson(const {}).isEmpty, isTrue);
  });

  test('what a contact sends is bounded and never throws', () {
    final hostile = <String, dynamic>{
      'pronouns': 42,
      'nickname': 'x' * 10000,
      'work': null,
      'family': ['not a map', 7, {'key': 1, 'label': 'ok', 'relation': 'x' * 500}],
      'languages': 'French',
      'websites': List.generate(100, (i) => 'https://$i.example'),
      'lifeEvents': [{'title': ''}, {'title': 'kept', 'date': 12}, 'junk'],
      'quotes': ['not', 'a', 'string'],
    };
    final about = ProfileAbout.fromJson(hostile);
    expect(about.pronouns, '');
    expect(about.nickname.length, ProfileAbout.shortLimit);
    expect(about.family.single.label, 'ok');
    expect(about.family.single.relation.length, 32);
    expect(about.languages, isEmpty, reason: 'a string is not a list');
    expect(about.websites.length, ProfileAbout.listLimit);
    expect(about.lifeEvents.map((e) => e.title), ['kept']);
    expect(about.quotes, '');
  });

  test('restricting to a field set blanks exactly the rest', () {
    final cut = full.restrictedTo({ProfileField.work, ProfileField.family});
    expect(cut.work, 'Researcher');
    expect(cut.family, full.family);
    expect(cut.city, '');
    expect(cut.partner, isNull);
    expect(cut.lifeEvents, isEmpty);
    expect(full.restrictedTo(ProfileField.about.toSet()), full);
    expect(full.restrictedTo(const {}).isEmpty, isTrue);
  });

  group('audience', () {
    test('contacts, spheres and me read back as written', () {
      for (final a in [
        FieldAudience.contacts,
        FieldAudience.me,
        FieldAudience.spheres({'s1', 's2'}),
      ]) {
        expect(FieldAudience.fromJson(jsonDecode(jsonEncode(a.toJson()))), a);
      }
    });

    test('an unknown audience means only me, and an empty sphere list too', () {
      expect(FieldAudience.fromJson('public'), FieldAudience.me);
      expect(FieldAudience.fromJson({'spheres': []}), FieldAudience.me);
      expect(FieldAudience.fromJson(null), FieldAudience.me);
    });

    test('allows is decided by the spheres a contact shares', () {
      final a = FieldAudience.spheres({'family'});
      expect(a.allows({'family', 'work'}), isTrue);
      expect(a.allows({'work'}), isFalse);
      expect(a.allows(const {}), isFalse);
      expect(FieldAudience.contacts.allows(const {}), isTrue);
      expect(FieldAudience.me.allows({'family'}), isFalse);
    });
  });

  test('a profile saved before about and audiences existed still reads', () {
    final old = {
      'publicKey': 'k',
      'displayName': 'Fai',
      'bio': 'hi',
      'updatedAt': '2026-10-11T10:00:00.000',
    };
    final p = UserProfile.fromJson(old);
    expect(p.about.isEmpty, isTrue);
    expect(p.audience, isEmpty);
    expect(p.avatarIsTemporary, isFalse);
    expect(p.legacyContact, isNull);
    // And writes no new keys when it has nothing to say.
    expect(p.toJson().keys.toSet(),
        {'publicKey', 'keyExchangePublicKey', 'displayName', 'bio', 'avatarRef', 'updatedAt'});
  });

  test('a profile with everything round-trips', () {
    final p = UserProfile(
      publicKey: 'k',
      displayName: 'Fai',
      bio: 'hi',
      updatedAt: DateTime(2026, 10, 11),
      birthday: '10-11',
      about: full,
      audience: {
        ProfileField.birthday: FieldAudience.spheres({'family'}),
        ProfileField.quotes: FieldAudience.me,
      },
      coverRef: '/c.jpg',
      featuredRefs: const ['/1.jpg', '/2.jpg'],
      avatarBefore: '/old.jpg',
      avatarUntil: DateTime(2026, 10, 12),
      legacyContact: 'k-sis',
    );
    expect(UserProfile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>), p);
  });

  test('a contact saved before about existed still reads', () {
    final c = Contact.fromJson({
      'publicKey': 'k',
      'displayName': 'Bob',
      'addedAt': '2026-10-11T10:00:00.000',
    });
    expect(c.about.isEmpty, isTrue);
    expect(c.bio, '');
    expect(c.namedMeLegacy, isFalse);
  });
}
