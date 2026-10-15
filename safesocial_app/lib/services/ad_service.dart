import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/advert.dart';
import 'ad_catalogue.dart';
import 'debug_log_service.dart';
import 'secure_store.dart';

/// Where the catalogue stands, for Settings to say in plain words.
enum CatalogueState {
  /// The operator shows no adverts ([NoAdverts]).
  notOffered,

  /// Never fetched yet this process.
  unknown,

  /// Fetched; may hold zero adverts.
  ready,

  /// The last fetch failed; whatever was fetched before stays.
  failed,
}

/// Adverts like a television break: after twenty minutes of watching, one
/// slot on Home, filled on the phone from the categories kept on.
///
/// The clock counts seconds on screen, any screen, and runs only while no
/// advert is waiting to be seen; the slot stays until closed, and the next
/// twenty minutes start then. The pick is the advert least recently shown
/// among those in an on category, so the same one does not come round while
/// others wait. Which categories are on, what was shown and when live in
/// one sealed store and nowhere else; the catalogue is fetched whole, so the
/// host cannot tell a category on from one off.
class AdService extends ChangeNotifier {
  static const _key = 'spheres_adverts_v1';

  /// Plain preference: a catalogue address set on this phone for testing.
  /// Not secret, like the relay host.
  static const testUrlKey = 'adverts_catalogue_url';
  static const adEvery = Duration(minutes: 20);

  /// The operator's source, the one every install gets.
  final AdCatalogue operatorCatalogue;
  AdCatalogue _catalogue;
  Uri? _testUrl;

  AdService({required AdCatalogue catalogue})
      : operatorCatalogue = catalogue,
        _catalogue = catalogue,
        _state = catalogue.offersAdverts
            ? CatalogueState.unknown
            : CatalogueState.notOffered;

  /// Where adverts come from now: the operator's source, or a catalogue
  /// address set on this phone for testing.
  AdCatalogue get catalogue => _catalogue;

  /// The testing address, when one is set.
  Uri? get testUrl => _testUrl;

  /// Supplies "now"; tests set it.
  DateTime Function() clock = DateTime.now;

  AdChoice _choice = AdChoice.everything();
  int _watched = 0;
  Advert? _current;
  final Map<String, int> _lastShown = {};
  List<Advert> _adverts = const [];
  CatalogueState _state;
  String? _failure;
  bool _foreground = false;
  Timer? _ticker;
  int _sinceSave = 0;

  AdChoice get choice => _choice;
  AdPlan get plan => _choice.plan;

  /// Seconds watched since the last slot.
  int get watchedSeconds => _watched;

  /// The advert on Home now, until [dismiss].
  Advert? get current => _current;

  CatalogueState get state => _state;
  String? get failure => _failure;
  List<Advert> get adverts => List.unmodifiable(_adverts);

  /// How many of the catalogue's adverts this phone would show, given its
  /// categories.
  int get eligibleCount => _eligible().length;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void onForeground() {
    if (_foreground) return;
    _foreground = true;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void onBackground() {
    if (!_foreground) return;
    _foreground = false;
    _ticker?.cancel();
    _ticker = null;
    unawaited(_persist());
  }

  /// One second of watching. Public so tests can advance time.
  void tick({int seconds = 1}) {
    // An advert is up and waiting to be seen; the next break is counted from
    // when it is closed, not stacked behind it.
    if (_current != null) return;
    _watched += seconds;
    _sinceSave += seconds;
    if (_watched >= adEvery.inSeconds) {
      _watched = 0;
      final pick = _pick();
      if (pick != null) {
        _current = pick;
        _lastShown[pick.id] = clock().millisecondsSinceEpoch;
        DebugLogService().info('Adverts', 'Slot filled: ${pick.id} (${pick.category})');
        unawaited(_persist());
      }
      notifyListeners();
    } else if (_sinceSave >= 30) {
      _sinceSave = 0;
      unawaited(_persist());
    }
  }

  /// The person closed the slot. The clock starts again.
  Future<void> dismiss() async {
    if (_current == null) return;
    _current = null;
    notifyListeners();
    await _persist();
  }

  // ── The pick ───────────────────────────────────────────────────────────────

  List<Advert> _eligible() =>
      [for (final a in _adverts) if (_choice.isOn(a.category)) a];

  /// Least recently shown first; never shown before any shown; ties by id, so
  /// the order is the same on every device given the same history.
  Advert? _pick() {
    final pool = _eligible();
    if (pool.isEmpty) return null;
    pool.sort((a, b) {
      final la = _lastShown[a.id] ?? -1, lb = _lastShown[b.id] ?? -1;
      if (la != lb) return la.compareTo(lb);
      return a.id.compareTo(b.id);
    });
    return pool.first;
  }

  // ── Choices ────────────────────────────────────────────────────────────────

  /// Turn a category on or off. Throws [StateError] when the plan's floor
  /// would be crossed; the switch is disabled before it comes to that.
  Future<void> setCategory(String id, bool on) async {
    _choice = _choice.set(id, on);
    final cur = _current;
    if (cur != null && !_choice.isOn(cur.category)) _current = null;
    notifyListeners();
    await _persist();
  }

  /// Change plan. A move to the free plan turns categories back on up to
  /// its floor. There is no way to buy a plan in the app yet; this is the
  /// seam where one would land.
  Future<void> setPlan(AdPlan plan) async {
    _choice = _choice.withPlan(plan);
    notifyListeners();
    await _persist();
  }

  // ── Catalogue ──────────────────────────────────────────────────────────────

  /// Point this phone at a catalogue of its own, to test the path before
  /// the operator carries any advert; null returns to the operator's source.
  /// Only http(s) is taken. The slot is emptied and the catalogue fetched.
  Future<void> setTestUrl(Uri? url) async {
    if (url != null && !(url.scheme == 'https' || url.scheme == 'http')) {
      throw ArgumentError.value(url, 'url', 'a catalogue address is http(s)');
    }
    _testUrl = url;
    _catalogue = url == null ? operatorCatalogue : JsonAdCatalogue(url);
    _current = null;
    _adverts = const [];
    _state = _catalogue.offersAdverts ? CatalogueState.unknown : CatalogueState.notOffered;
    _failure = null;
    final prefs = await SharedPreferences.getInstance();
    if (url == null) {
      await prefs.remove(testUrlKey);
    } else {
      await prefs.setString(testUrlKey, url.toString());
    }
    notifyListeners();
    await refreshCatalogue();
  }

  /// Fill the slot as if twenty minutes had passed, for testing on a phone.
  /// Does nothing while one is up; returns whether one was found.
  bool fillSlotNow() {
    if (_current != null) return false;
    _watched = adEvery.inSeconds;
    tick(seconds: 0);
    return _current != null;
  }

  /// Fetch the catalogue. A failure keeps the last one and is said in
  /// [state] and [failure]; nothing here pretends.
  Future<void> refreshCatalogue() async {
    final catalogue = _catalogue;
    if (!catalogue.offersAdverts) {
      _state = CatalogueState.notOffered;
      _adverts = const [];
      notifyListeners();
      return;
    }
    try {
      _adverts = await catalogue.fetch();
      _state = CatalogueState.ready;
      _failure = null;
      // What was shown that the catalogue no longer carries is forgotten.
      final ids = {for (final a in _adverts) a.id};
      _lastShown.removeWhere((id, _) => !ids.contains(id));
      final cur = _current;
      if (cur != null && !ids.contains(cur.id)) _current = null;
      DebugLogService().info('Adverts', 'Catalogue: ${_adverts.length} adverts');
    } catch (e) {
      _state = CatalogueState.failed;
      _failure = '$e';
      DebugLogService().warn('Adverts', 'Catalogue not fetched: $e');
    }
    notifyListeners();
  }

  // ── Storage ────────────────────────────────────────────────────────────────

  Future<void> _persist() => SecureStore.instance.setString(
        _key,
        jsonEncode({
          'choice': _choice.toJson(),
          'watched': _watched,
          'shown': _lastShown,
        }),
      );

  Future<void> load() async {
    final stored = (await SharedPreferences.getInstance()).getString(testUrlKey);
    final url = stored == null ? null : Uri.tryParse(stored);
    if (url != null && (url.scheme == 'https' || url.scheme == 'http')) {
      _testUrl = url;
      _catalogue = JsonAdCatalogue(url);
      _state = CatalogueState.unknown;
    }
    final raw = await SecureStore.instance.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final c = j['choice'];
      if (c is Map<String, dynamic>) _choice = AdChoice.fromJson(c);
      _watched = j['watched'] is int ? (j['watched'] as int).clamp(0, adEvery.inSeconds) : 0;
      _lastShown.clear();
      (j['shown'] as Map?)?.forEach((k, v) {
        if (v is int) _lastShown['$k'] = v;
      });
    } catch (e) {
      DebugLogService().warn('Adverts', 'Stored choice unreadable, starting afresh: $e');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
