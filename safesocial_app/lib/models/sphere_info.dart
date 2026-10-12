import 'package:equatable/equatable.dart';

import 'profile_about.dart';

/// A named, ordered set of posts: a guide.
class SphereUnit with EquatableMixin {
  final String id;
  final String title;
  final List<String> postIds;
  const SphereUnit({required this.id, required this.title, this.postIds = const []});

  factory SphereUnit.fromJson(Map<String, dynamic> j) => SphereUnit(
        id: ProfileAbout.text(j['id'], 64),
        title: ProfileAbout.text(j['title'], 80),
        postIds: (j['posts'] as List?)?.whereType<String>().take(100).toList() ?? const [],
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'posts': postIds};

  SphereUnit copyWith({String? title, List<String>? postIds}) =>
      SphereUnit(id: id, title: title ?? this.title, postIds: postIds ?? this.postIds);

  @override
  List<Object?> get props => [id, title, postIds];
}

/// What a sphere's admins have decided about it beyond membership: rules,
/// questions a joiner answers, topics for posts, a welcome line, guides,
/// badges, suspensions, and the automation the admins chose. It travels as a
/// signed sphere item from an admin; every member keeps the newest version.
class SphereInfo with EquatableMixin {
  final String sphereId;
  final int version;
  final String by;
  final DateTime updatedAt;
  final List<String> rules;
  final List<String> questions;
  final List<String> topics;
  final String welcome;
  final List<SphereUnit> units;
  final Map<String, List<String>> badges;
  final Map<String, DateTime> suspended;

  /// Mute a member on every admin's device once this many reports name
  /// their posts; 0 is off.
  final int autoMuteReports;

  /// Invite links older than this many days are retired before being shown
  /// again; 0 means they last until reset.
  final int inviteDays;

  const SphereInfo({
    required this.sphereId,
    this.version = 0,
    this.by = '',
    required this.updatedAt,
    this.rules = const [],
    this.questions = const [],
    this.topics = const [],
    this.welcome = '',
    this.units = const [],
    this.badges = const {},
    this.suspended = const {},
    this.autoMuteReports = 0,
    this.inviteDays = 0,
  });

  factory SphereInfo.empty(String sphereId) =>
      SphereInfo(sphereId: sphereId, updatedAt: DateTime.fromMillisecondsSinceEpoch(0));

  static List<String> _strings(Object? v, int max, int each) =>
      (v as List?)?.whereType<String>().map((s) => ProfileAbout.text(s, each)).where((s) => s.isNotEmpty).take(max).toList() ??
      const [];

  factory SphereInfo.fromJson(Map<String, dynamic> j) {
    final badges = <String, List<String>>{};
    if (j['badges'] is Map) {
      for (final e in (j['badges'] as Map).entries.take(200)) {
        final list = _strings(e.value, 5, 24);
        if (list.isNotEmpty) badges['${e.key}'] = list;
      }
    }
    final suspended = <String, DateTime>{};
    if (j['suspended'] is Map) {
      for (final e in (j['suspended'] as Map).entries.take(200)) {
        final until = DateTime.tryParse('${e.value}');
        if (until != null) suspended['${e.key}'] = until;
      }
    }
    return SphereInfo(
      sphereId: j['sphereId'] as String,
      version: j['version'] is int ? j['version'] as int : 0,
      by: j['by'] is String ? j['by'] as String : '',
      updatedAt: DateTime.tryParse('${j['updatedAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
      rules: _strings(j['rules'], 20, 300),
      questions: _strings(j['questions'], 3, 120),
      topics: _strings(j['topics'], 20, 40),
      welcome: ProfileAbout.text(j['welcome'], 300),
      units: (j['units'] as List?)
              ?.whereType<Map>()
              .map((m) => SphereUnit.fromJson(m.cast<String, dynamic>()))
              .where((u) => u.id.isNotEmpty)
              .take(20)
              .toList() ??
          const [],
      badges: badges,
      suspended: suspended,
      autoMuteReports: (j['autoMuteReports'] is int ? j['autoMuteReports'] as int : 0).clamp(0, 100),
      inviteDays: (j['inviteDays'] is int ? j['inviteDays'] as int : 0).clamp(0, 365),
    );
  }

  Map<String, dynamic> toJson() => {
        'sphereId': sphereId,
        'version': version,
        'by': by,
        'updatedAt': updatedAt.toIso8601String(),
        if (rules.isNotEmpty) 'rules': rules,
        if (questions.isNotEmpty) 'questions': questions,
        if (topics.isNotEmpty) 'topics': topics,
        if (welcome.isNotEmpty) 'welcome': welcome,
        if (units.isNotEmpty) 'units': [for (final u in units) u.toJson()],
        if (badges.isNotEmpty) 'badges': badges,
        if (suspended.isNotEmpty) 'suspended': suspended.map((k, v) => MapEntry(k, v.toIso8601String())),
        if (autoMuteReports > 0) 'autoMuteReports': autoMuteReports,
        if (inviteDays > 0) 'inviteDays': inviteDays,
      };

  bool get isEmpty =>
      rules.isEmpty && questions.isEmpty && topics.isEmpty && welcome.isEmpty && units.isEmpty &&
      badges.isEmpty && suspended.isEmpty && autoMuteReports == 0 && inviteDays == 0;

  /// Whether [member] is suspended at [now].
  bool isSuspended(String member, {DateTime? now}) {
    final until = suspended[member];
    return until != null && (now ?? DateTime.now()).isBefore(until);
  }

  List<String> badgesOf(String member) => badges[member] ?? const [];

  SphereInfo copyWith({
    int? version,
    String? by,
    DateTime? updatedAt,
    List<String>? rules,
    List<String>? questions,
    List<String>? topics,
    String? welcome,
    List<SphereUnit>? units,
    Map<String, List<String>>? badges,
    Map<String, DateTime>? suspended,
    int? autoMuteReports,
    int? inviteDays,
  }) =>
      SphereInfo(
        sphereId: sphereId,
        version: version ?? this.version,
        by: by ?? this.by,
        updatedAt: updatedAt ?? this.updatedAt,
        rules: rules ?? this.rules,
        questions: questions ?? this.questions,
        topics: topics ?? this.topics,
        welcome: welcome ?? this.welcome,
        units: units ?? this.units,
        badges: badges ?? this.badges,
        suspended: suspended ?? this.suspended,
        autoMuteReports: autoMuteReports ?? this.autoMuteReports,
        inviteDays: inviteDays ?? this.inviteDays,
      );

  @override
  List<Object?> get props =>
      [sphereId, version, by, updatedAt, rules, questions, topics, welcome, units, badges, suspended, autoMuteReports, inviteDays];
}
