/// Advertisements, the television way: a slot every twenty minutes of
/// watching, filled from categories the person chose, chosen on the phone.
///
/// Nothing about the person is read or sent to decide what shows. The device
/// fetches the whole catalogue, every category, and picks locally from the
/// categories kept on; nobody is told which ones those are, which advert was
/// shown, or that one was shown at all. A free plan keeps at least
/// [AdPlan.freeMinimum] categories on; a paid plan may turn every one off.
library;

/// One thing an advert can be about. The list is fixed in the app so a
/// catalogue cannot invent a category the person never saw in Settings.
class AdCategory {
  final String id;
  final String label;
  const AdCategory._(this.id, this.label);

  static const all = <AdCategory>[
    AdCategory._('books', 'Books and reading'),
    AdCategory._('music', 'Music'),
    AdCategory._('film', 'Film and television'),
    AdCategory._('games', 'Games'),
    AdCategory._('sport', 'Sport'),
    AdCategory._('outdoors', 'Outdoors and travel'),
    AdCategory._('food', 'Food and drink'),
    AdCategory._('home', 'Home and garden'),
    AdCategory._('fashion', 'Clothing and fashion'),
    AdCategory._('beauty', 'Beauty and care'),
    AdCategory._('health', 'Health and fitness'),
    AdCategory._('family', 'Family and children'),
    AdCategory._('pets', 'Pets'),
    AdCategory._('education', 'Learning and courses'),
    AdCategory._('technology', 'Technology'),
    AdCategory._('software', 'Software and apps'),
    AdCategory._('cars', 'Cars and transport'),
    AdCategory._('finance', 'Money and insurance'),
    AdCategory._('property', 'Property'),
    AdCategory._('jobs', 'Work and careers'),
    AdCategory._('arts', 'Arts and crafts'),
    AdCategory._('events', 'Events and tickets'),
    AdCategory._('charity', 'Charities and causes'),
    AdCategory._('local', 'Local businesses'),
  ];

  static final Set<String> ids = {for (final c in all) c.id};

  static AdCategory? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  static String labelOf(String id) => byId(id)?.label ?? id;
}

/// Who pays for the app decides how many categories must stay on.
enum AdPlan {
  free,
  paid;

  /// The fewest categories a plan lets the person keep on.
  int get minimumCategories => this == AdPlan.free ? freeMinimum : 0;

  static const freeMinimum = 10;

  static AdPlan parse(Object? v) => v == 'paid' ? AdPlan.paid : AdPlan.free;
}

/// Which categories are on, with the plan's floor applied. Pure.
class AdChoice {
  final AdPlan plan;
  final Set<String> on;

  AdChoice({required this.plan, required Set<String> on})
      : on = Set.unmodifiable(on.where(AdCategory.ids.contains));

  /// Every category on: what a fresh install starts with.
  factory AdChoice.everything({AdPlan plan = AdPlan.free}) =>
      AdChoice(plan: plan, on: AdCategory.ids);

  int get minimum => plan.minimumCategories;

  bool isOn(String id) => on.contains(id);

  /// Whether one more category may be turned off under this plan.
  bool get canTurnOneOff => on.length > minimum;

  /// Turn a category on or off. Turning one off below the plan's floor is
  /// refused with a [StateError], so a caller that did not look at
  /// [canTurnOneOff] first hears about it rather than silently keeping it on.
  AdChoice set(String id, bool value) {
    if (!AdCategory.ids.contains(id)) {
      throw ArgumentError.value(id, 'id', 'not an advert category');
    }
    if (value == isOn(id)) return this;
    if (!value && !canTurnOneOff) {
      throw StateError(
          'The ${plan.name} plan keeps at least $minimum categories on');
    }
    final next = {...on};
    value ? next.add(id) : next.remove(id);
    return AdChoice(plan: plan, on: next);
  }

  /// Move to another plan. A move to a plan with a higher floor turns
  /// categories back on, in the fixed list's order, until the floor is met;
  /// a move to a lower one changes nothing.
  AdChoice withPlan(AdPlan next) {
    final set = {...on};
    for (final c in AdCategory.all) {
      if (set.length >= next.minimumCategories) break;
      set.add(c.id);
    }
    return AdChoice(plan: next, on: set);
  }

  Map<String, dynamic> toJson() => {'plan': plan.name, 'on': on.toList()..sort()};

  static AdChoice fromJson(Map<String, dynamic> j) {
    final plan = AdPlan.parse(j['plan']);
    final raw = j['on'];
    final on = raw is List ? {for (final v in raw) if (v is String) v} : <String>{};
    // A stored choice from a stricter time, or a hand-edited one, is brought
    // up to the plan's floor rather than trusted.
    return AdChoice(plan: plan, on: on).withPlan(plan);
  }
}

/// One advert from the catalogue. Text only: a title, a line, who paid, and
/// a link that opens only when it is http(s).
class Advert {
  final String id;
  final String category;
  final String title;
  final String body;
  final String sponsor;
  final Uri? link;

  const Advert({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.sponsor,
    this.link,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category,
        'title': title,
        'body': body,
        'sponsor': sponsor,
        if (link != null) 'link': link.toString(),
      };

  /// Null for anything short of a whole advert in a known category; the
  /// catalogue drops those rather than show a half one.
  static Advert? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], category = raw['category'];
    final title = raw['title'], body = raw['body'], sponsor = raw['sponsor'];
    if (id is! String || id.isEmpty || id.length > 64) return null;
    if (category is! String || !AdCategory.ids.contains(category)) return null;
    if (title is! String || title.trim().isEmpty || title.length > 80) {
      return null;
    }
    if (body is! String || body.length > 280) return null;
    if (sponsor is! String || sponsor.trim().isEmpty || sponsor.length > 60) {
      return null;
    }
    Uri? link;
    final l = raw['link'];
    if (l is String && l.isNotEmpty) {
      final u = Uri.tryParse(l);
      if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) {
        return null;
      }
      link = u;
    }
    return Advert(
      id: id,
      category: category,
      title: title.trim(),
      body: body.trim(),
      sponsor: sponsor.trim(),
      link: link,
    );
  }

  /// Why this advert and not another, in the viewer's words. Always true,
  /// because the choice is made this way and no other.
  String get why =>
      'Chosen on this phone from the categories you keep on, under "${AdCategory.labelOf(category)}". '
      'Nothing about you, your choice or this advert left the phone. '
      'Categories are in Settings, Advertisements.';
}
