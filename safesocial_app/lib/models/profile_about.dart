import 'package:equatable/equatable.dart';

/// Who may see one profile field.
///
/// `contacts` is every contact; `spheres` is only contacts who share at least
/// one of the named spheres with us; `me` leaves the device never. There is
/// no "public": nothing about a person is public here.
class FieldAudience with EquatableMixin {
  final String mode; // contacts | spheres | me
  final Set<String> sphereIds;

  const FieldAudience._(this.mode, this.sphereIds);

  static const contacts = FieldAudience._('contacts', {});
  static const me = FieldAudience._('me', {});
  factory FieldAudience.spheres(Set<String> ids) =>
      ids.isEmpty ? me : FieldAudience._('spheres', Set.unmodifiable(ids));

  bool get isContacts => mode == 'contacts';
  bool get isMe => mode == 'me';
  bool get isSpheres => mode == 'spheres';

  /// Whether a contact who shares [shared] spheres with us may see the field.
  bool allows(Set<String> shared) {
    if (isContacts) return true;
    if (isMe) return false;
    return sphereIds.any(shared.contains);
  }

  factory FieldAudience.fromJson(Object? json) {
    if (json is String) {
      if (json == 'contacts') return contacts;
      if (json == 'me') return me;
    }
    if (json is Map && json['spheres'] is List) {
      return FieldAudience.spheres(
          (json['spheres'] as List).whereType<String>().toSet());
    }
    // Unknown: the safe reading is "only me".
    return me;
  }

  Object toJson() => isSpheres ? {'spheres': sphereIds.toList()} : mode;

  String describe(String Function(String sphereId) sphereName) {
    if (isContacts) return 'All contacts';
    if (isMe) return 'Only me';
    return sphereIds.map(sphereName).join(', ');
  }

  @override
  List<Object?> get props => [mode, sphereIds];
}

/// A dated thing worth telling people about: a move, a new job, a birth.
class LifeEvent with EquatableMixin {
  final String title;
  final String date; // YYYY-MM or YYYY-MM-DD, as typed; never parsed for logic
  final String note;

  const LifeEvent({required this.title, this.date = '', this.note = ''});

  factory LifeEvent.fromJson(Map<String, dynamic> j) => LifeEvent(
        title: ProfileAbout.text(j['title'], ProfileAbout.shortLimit),
        date: ProfileAbout.text(j['date'], 16),
        note: ProfileAbout.text(j['note'], ProfileAbout.longLimit),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        if (date.isNotEmpty) 'date': date,
        if (note.isNotEmpty) 'note': note,
      };

  @override
  List<Object?> get props => [title, date, note];
}

/// Someone named on the profile: a partner or a family member. The key is a
/// contact's identity key, so the reader can resolve it to a name they know;
/// [label] is what to show when they cannot.
class NamedPerson with EquatableMixin {
  final String key;
  final String label;
  final String relation; // partner, parent, child, sibling, …

  const NamedPerson({required this.key, this.label = '', this.relation = ''});

  factory NamedPerson.fromJson(Map<String, dynamic> j) => NamedPerson(
        key: ProfileAbout.text(j['key'], 128),
        label: ProfileAbout.text(j['label'], ProfileAbout.shortLimit),
        relation: ProfileAbout.text(j['relation'], 32),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        if (label.isNotEmpty) 'label': label,
        if (relation.isNotEmpty) 'relation': relation,
      };

  @override
  List<Object?> get props => [key, label, relation];
}

/// Everything a profile says beyond name, bio, picture and birthday.
///
/// Every field has a name in [ProfileField] so an audience can be attached to
/// it, and every string is bounded, because this is parsed from what a
/// contact sent. A reader never throws on it: [ProfileAbout.fromJson] takes
/// what fits and drops the rest.
class ProfileAbout with EquatableMixin {
  static const shortLimit = 80;
  static const longLimit = 400;
  static const listLimit = 12;

  final String pronouns;
  final String nickname;
  final String pronunciation;
  final String work;
  final String education;
  final String city;
  final String hometown;
  final String relationshipStatus; // free text: single, married, …
  final NamedPerson? partner;
  final List<NamedPerson> family;
  final List<String> languages;
  final List<String> websites;
  final List<String> hobbies;
  final String quotes;
  final List<LifeEvent> lifeEvents;

  const ProfileAbout({
    this.pronouns = '',
    this.nickname = '',
    this.pronunciation = '',
    this.work = '',
    this.education = '',
    this.city = '',
    this.hometown = '',
    this.relationshipStatus = '',
    this.partner,
    this.family = const [],
    this.languages = const [],
    this.websites = const [],
    this.hobbies = const [],
    this.quotes = '',
    this.lifeEvents = const [],
  });

  static const empty = ProfileAbout();

  bool get isEmpty => this == empty;

  /// A bounded string from whatever was sent; anything else is ''.
  static String text(Object? v, int limit) {
    if (v is! String) return '';
    final t = v.trim();
    return t.length <= limit ? t : t.substring(0, limit);
  }

  static List<String> strings(Object? v, int limit) {
    if (v is! List) return const [];
    return v
        .whereType<String>()
        .map((s) => text(s, limit))
        .where((s) => s.isNotEmpty)
        .take(listLimit)
        .toList();
  }

  static List<T> objects<T>(Object? v, T Function(Map<String, dynamic>) make) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((m) => make(m.cast<String, dynamic>()))
        .take(listLimit)
        .toList();
  }

  factory ProfileAbout.fromJson(Map<String, dynamic> j) {
    final partner = j['partner'];
    return ProfileAbout(
      pronouns: text(j['pronouns'], 32),
      nickname: text(j['nickname'], shortLimit),
      pronunciation: text(j['pronunciation'], shortLimit),
      work: text(j['work'], shortLimit),
      education: text(j['education'], shortLimit),
      city: text(j['city'], shortLimit),
      hometown: text(j['hometown'], shortLimit),
      relationshipStatus: text(j['relationship'], 32),
      partner: partner is Map
          ? NamedPerson.fromJson(partner.cast<String, dynamic>())
          : null,
      family: objects(j['family'], NamedPerson.fromJson)
          .where((p) => p.key.isNotEmpty || p.label.isNotEmpty)
          .toList(),
      languages: strings(j['languages'], 32),
      websites: strings(j['websites'], 200),
      hobbies: strings(j['hobbies'], 32),
      quotes: text(j['quotes'], longLimit),
      lifeEvents: objects(j['lifeEvents'], LifeEvent.fromJson)
          .where((e) => e.title.isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (pronouns.isNotEmpty) 'pronouns': pronouns,
        if (nickname.isNotEmpty) 'nickname': nickname,
        if (pronunciation.isNotEmpty) 'pronunciation': pronunciation,
        if (work.isNotEmpty) 'work': work,
        if (education.isNotEmpty) 'education': education,
        if (city.isNotEmpty) 'city': city,
        if (hometown.isNotEmpty) 'hometown': hometown,
        if (relationshipStatus.isNotEmpty) 'relationship': relationshipStatus,
        if (partner != null) 'partner': partner!.toJson(),
        if (family.isNotEmpty) 'family': family.map((p) => p.toJson()).toList(),
        if (languages.isNotEmpty) 'languages': languages,
        if (websites.isNotEmpty) 'websites': websites,
        if (hobbies.isNotEmpty) 'hobbies': hobbies,
        if (quotes.isNotEmpty) 'quotes': quotes,
        if (lifeEvents.isNotEmpty)
          'lifeEvents': lifeEvents.map((e) => e.toJson()).toList(),
      };

  /// The same profile with every field not in [keep] blanked. This is how a
  /// copy for one contact is cut down to what they may see.
  ProfileAbout restrictedTo(Set<String> keep) => ProfileAbout(
        pronouns: keep.contains(ProfileField.pronouns) ? pronouns : '',
        nickname: keep.contains(ProfileField.nickname) ? nickname : '',
        pronunciation:
            keep.contains(ProfileField.pronunciation) ? pronunciation : '',
        work: keep.contains(ProfileField.work) ? work : '',
        education: keep.contains(ProfileField.education) ? education : '',
        city: keep.contains(ProfileField.city) ? city : '',
        hometown: keep.contains(ProfileField.hometown) ? hometown : '',
        relationshipStatus:
            keep.contains(ProfileField.relationship) ? relationshipStatus : '',
        partner: keep.contains(ProfileField.relationship) ? partner : null,
        family: keep.contains(ProfileField.family) ? family : const [],
        languages: keep.contains(ProfileField.languages) ? languages : const [],
        websites: keep.contains(ProfileField.websites) ? websites : const [],
        hobbies: keep.contains(ProfileField.hobbies) ? hobbies : const [],
        quotes: keep.contains(ProfileField.quotes) ? quotes : '',
        lifeEvents:
            keep.contains(ProfileField.lifeEvents) ? lifeEvents : const [],
      );

  ProfileAbout copyWith({
    String? pronouns,
    String? nickname,
    String? pronunciation,
    String? work,
    String? education,
    String? city,
    String? hometown,
    String? relationshipStatus,
    NamedPerson? partner,
    bool clearPartner = false,
    List<NamedPerson>? family,
    List<String>? languages,
    List<String>? websites,
    List<String>? hobbies,
    String? quotes,
    List<LifeEvent>? lifeEvents,
  }) =>
      ProfileAbout(
        pronouns: pronouns ?? this.pronouns,
        nickname: nickname ?? this.nickname,
        pronunciation: pronunciation ?? this.pronunciation,
        work: work ?? this.work,
        education: education ?? this.education,
        city: city ?? this.city,
        hometown: hometown ?? this.hometown,
        relationshipStatus: relationshipStatus ?? this.relationshipStatus,
        partner: clearPartner ? null : (partner ?? this.partner),
        family: family ?? this.family,
        languages: languages ?? this.languages,
        websites: websites ?? this.websites,
        hobbies: hobbies ?? this.hobbies,
        quotes: quotes ?? this.quotes,
        lifeEvents: lifeEvents ?? this.lifeEvents,
      );

  @override
  List<Object?> get props => [
        pronouns,
        nickname,
        pronunciation,
        work,
        education,
        city,
        hometown,
        relationshipStatus,
        partner,
        family,
        languages,
        websites,
        hobbies,
        quotes,
        lifeEvents,
      ];
}

/// The names fields go by in the audience map and on the wire.
class ProfileField {
  ProfileField._();

  static const bio = 'bio';
  static const birthday = 'birthday';
  static const avatar = 'avatar';
  static const cover = 'cover';
  static const featured = 'featured';
  static const pronouns = 'pronouns';
  static const nickname = 'nickname';
  static const pronunciation = 'pronunciation';
  static const work = 'work';
  static const education = 'education';
  static const city = 'city';
  static const hometown = 'hometown';
  static const relationship = 'relationship';
  static const family = 'family';
  static const languages = 'languages';
  static const websites = 'websites';
  static const hobbies = 'hobbies';
  static const quotes = 'quotes';
  static const lifeEvents = 'lifeEvents';
  static const pinned = 'pinned';
  static const highlights = 'highlights';
  static const note = 'note';

  /// Every field that can carry an audience, in display order. The name and
  /// picture are not here: a contact who cannot see your name is not a
  /// contact.
  static const all = [
    bio,
    birthday,
    cover,
    featured,
    pronouns,
    nickname,
    pronunciation,
    work,
    education,
    city,
    hometown,
    relationship,
    family,
    languages,
    websites,
    hobbies,
    quotes,
    lifeEvents,
    pinned,
    highlights,
    note,
  ];

  /// The ones that live inside [ProfileAbout].
  static const about = [
    pronouns,
    nickname,
    pronunciation,
    work,
    education,
    city,
    hometown,
    relationship,
    family,
    languages,
    websites,
    hobbies,
    quotes,
    lifeEvents,
  ];

  static String label(String field) => switch (field) {
        bio => 'Bio',
        birthday => 'Birthday',
        avatar => 'Profile picture',
        cover => 'Cover photo',
        featured => 'Featured photos',
        pronouns => 'Pronouns',
        nickname => 'Nickname',
        pronunciation => 'Name pronunciation',
        work => 'Work',
        education => 'Education',
        city => 'Current city',
        hometown => 'Hometown',
        relationship => 'Relationship',
        family => 'Family',
        languages => 'Languages',
        websites => 'Websites',
        hobbies => 'Hobbies',
        quotes => 'Favourite quotes',
        lifeEvents => 'Life events',
        pinned => 'Pinned posts',
        highlights => 'Story highlights',
        note => 'Note',
        _ => field,
      };
}
