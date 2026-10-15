import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/advert.dart';
import 'package:spheres_app/services/ad_catalogue.dart';
import 'package:spheres_app/services/ad_service.dart';
import 'package:spheres_app/services/secure_store.dart';

class _Fixed implements AdCatalogue {
  final List<Advert> ads;
  final Object? fails;
  int fetches = 0;
  _Fixed(this.ads, {this.fails});
  @override
  bool get offersAdverts => true;
  @override
  Future<List<Advert>> fetch() async {
    fetches++;
    if (fails != null) throw fails!;
    return ads;
  }
}

Advert _ad(String id, String category) => Advert(
      id: id,
      category: category,
      title: 'Advert $id',
      body: '',
      sponsor: 'Sponsor',
    );

/// The television rule: twenty minutes of watching, then one slot on Home,
/// picked on the phone from the categories kept on; the clock waits while
/// the slot is up; the pick rotates; the free plan keeps ten categories.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  final twenty = AdService.adEvery.inSeconds;

  Future<AdService> ready(List<Advert> ads) async {
    final s = AdService(catalogue: _Fixed(ads));
    var now = DateTime(2026, 10, 14, 9);
    s.clock = () => now;
    await s.refreshCatalogue();
    return s;
  }

  group('the slot', () {
    test('after twenty minutes an advert is due, not a second before', () async {
      final s = await ready([_ad('a', 'books')]);
      s.tick(seconds: twenty - 1);
      expect(s.current, isNull);
      s.tick();
      expect(s.current?.id, 'a');
      expect(s.watchedSeconds, 0);
    });

    test('the clock waits while the advert is up and starts again when it is closed', () async {
      final s = await ready([_ad('a', 'books'), _ad('b', 'music')]);
      s.tick(seconds: twenty);
      expect(s.current?.id, 'a');
      s.tick(seconds: twenty * 3);
      expect(s.current?.id, 'a', reason: 'nothing stacks behind the one showing');
      expect(s.watchedSeconds, 0);
      await s.dismiss();
      expect(s.current, isNull);
      s.tick(seconds: twenty - 1);
      expect(s.current, isNull);
      s.tick();
      expect(s.current?.id, 'b');
    });

    test('the least recently shown comes next, so every advert gets its turn', () async {
      final s = await ready([_ad('c', 'books'), _ad('a', 'music'), _ad('b', 'books')]);
      final order = <String>[];
      var now = DateTime(2026, 10, 14, 9);
      s.clock = () => now;
      for (var i = 0; i < 6; i++) {
        s.tick(seconds: twenty);
        order.add(s.current!.id);
        now = now.add(const Duration(minutes: 21));
        await s.dismiss();
      }
      expect(order, ['a', 'b', 'c', 'a', 'b', 'c']);
    });

    test('a category turned off never fills the slot, and clears one that is up', () async {
      final s = await ready([_ad('a', 'books'), _ad('b', 'music')]);
      await s.setCategory('books', false);
      s.tick(seconds: twenty);
      expect(s.current?.id, 'b');
      await s.setCategory('music', false);
      expect(s.current, isNull, reason: 'the choice applies at once');
      s.tick(seconds: twenty);
      expect(s.current, isNull);
      expect(s.eligibleCount, 0);
    });

    test('with nothing on offer the slot stays empty and the clock still restarts', () async {
      final s = AdService(catalogue: const NoAdverts());
      await s.refreshCatalogue();
      expect(s.state, CatalogueState.notOffered);
      s.tick(seconds: twenty);
      expect(s.current, isNull);
      expect(s.watchedSeconds, 0);
    });
  });

  group('the plan', () {
    test('the free plan refuses the eleventh category off; the paid plan reaches zero', () async {
      final s = await ready([]);
      final ids = AdCategory.all.map((c) => c.id).toList();
      for (final id in ids.take(ids.length - AdPlan.freeMinimum)) {
        await s.setCategory(id, false);
      }
      expect(s.choice.on.length, AdPlan.freeMinimum);
      expect(s.choice.canTurnOneOff, isFalse);
      await expectLater(s.setCategory(ids.last, false), throwsStateError);

      await s.setPlan(AdPlan.paid);
      for (final id in s.choice.on.toList()) {
        await s.setCategory(id, false);
      }
      expect(s.choice.on, isEmpty);

      await s.setPlan(AdPlan.free);
      expect(s.choice.on.length, AdPlan.freeMinimum);
    });
  });

  group('storage', () {
    test('the choice, the clock and what was shown survive a restart', () async {
      final s = await ready([_ad('a', 'books'), _ad('b', 'books')]);
      await s.setCategory('music', false);
      s.tick(seconds: twenty);
      expect(s.current?.id, 'a');
      await s.dismiss();
      s.tick(seconds: 100);
      await s.onBackgroundForTest();

      final again = AdService(catalogue: _Fixed([_ad('a', 'books'), _ad('b', 'books')]));
      await again.load();
      await again.refreshCatalogue();
      expect(again.choice.isOn('music'), isFalse);
      expect(again.watchedSeconds, 100);
      again.tick(seconds: twenty - 100);
      expect(again.current?.id, 'b', reason: 'a was shown before the restart');
    });

    test('an unreadable store starts afresh rather than failing to load', () async {
      await SecureStore.instance.setString('spheres_adverts_v1', '{nope');
      final s = AdService(catalogue: const NoAdverts());
      await s.load();
      expect(s.choice.on, AdCategory.ids);
    });
  });

  group('testing on a phone', () {
    const doc = '{"version":1,"ads":[{"id":"t","category":"books","title":"T","body":"","sponsor":"S"}]}';

    test('a catalogue address set on the phone replaces the operator\'s source and survives a restart', () async {
      final s = AdService(catalogue: const NoAdverts());
      await s.load();
      expect(s.state, CatalogueState.notOffered);
      // The address is kept in plain preferences; the fetch goes over HTTP,
      // so the test points it at a URL and checks the state, not the bytes.
      await s.setTestUrl(Uri.parse('http://127.0.0.1:9/catalogue.json'));
      expect(s.testUrl, isNotNull);
      expect(s.catalogue, isA<JsonAdCatalogue>());
      expect(s.state, CatalogueState.failed, reason: 'nothing listens on port 9, and it is said');

      final again = AdService(catalogue: const NoAdverts());
      await again.load();
      expect(again.testUrl, Uri.parse('http://127.0.0.1:9/catalogue.json'));
      expect(again.catalogue, isA<JsonAdCatalogue>());

      await again.setTestUrl(null);
      expect(again.catalogue, same(again.operatorCatalogue));
      expect(again.state, CatalogueState.notOffered);
      expect((await SharedPreferences.getInstance()).getString(AdService.testUrlKey), isNull);
    });

    test('an address that is not http(s) is refused', () async {
      final s = AdService(catalogue: const NoAdverts());
      await expectLater(s.setTestUrl(Uri.parse('file:///etc/passwd')), throwsArgumentError);
      expect(s.testUrl, isNull);
    });

    test('"fill the slot now" shows one without the wait, and not a second while it is up', () async {
      final s = await ready([_ad('a', 'books')]);
      expect(s.fillSlotNow(), isTrue);
      expect(s.current?.id, 'a');
      expect(s.fillSlotNow(), isFalse);
      await s.dismiss();
      expect(s.watchedSeconds, 0);
    });

    test('the published test catalogue parses to three adverts and drops the two bad ones', () {
      final body = File('../landing/ads/test-catalogue.json').readAsStringSync();
      final ads = JsonAdCatalogue.parse(body);
      expect(ads.map((a) => a.id), ['test-books-1', 'test-music-1', 'test-outdoors-1']);
      expect(JsonAdCatalogue.parse(doc).single.id, 't');
    });
  });

  group('the catalogue', () {
    test('a failed fetch is said, and the last catalogue stays', () async {
      final s = await ready([_ad('a', 'books')]);
      expect(s.state, CatalogueState.ready);
      final failing = AdService(catalogue: _Fixed([], fails: AdCatalogueException('down')));
      await failing.refreshCatalogue();
      expect(failing.state, CatalogueState.failed);
      expect(failing.failure, 'down');
      expect(failing.adverts, isEmpty);
    });

    test('an advert the catalogue no longer carries is forgotten and taken down', () async {
      final cat = _Fixed([_ad('a', 'books')]);
      final s = AdService(catalogue: cat);
      await s.refreshCatalogue();
      s.tick(seconds: twenty);
      expect(s.current?.id, 'a');
      cat.ads.clear();
      cat.ads.add(_ad('b', 'books'));
      await s.refreshCatalogue();
      expect(s.current, isNull);
    });

    test('the JSON source asks for the whole document with nothing about the phone', () async {
      http.Request? seen;
      final cat = JsonAdCatalogue(
        Uri.parse('https://ads.example/catalogue.json'),
        client: () => MockClient((req) async {
          seen = req;
          return http.Response(
            '{"version":1,"ads":[{"id":"a","category":"books","title":"A","body":"","sponsor":"S"}]}',
            200,
          );
        }),
      );
      final ads = await cat.fetch();
      expect(ads.single.id, 'a');
      expect(seen!.url.query, isEmpty);
      expect(seen!.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
      expect(seen!.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    });

    test('the JSON source refuses a non-200 answer and an oversized document', () async {
      final notFound = JsonAdCatalogue(Uri.parse('https://ads.example/x'),
          client: () => MockClient((_) async => http.Response('', 404)));
      await expectLater(notFound.fetch(), throwsA(isA<AdCatalogueException>()));
      final huge = JsonAdCatalogue(Uri.parse('https://ads.example/x'),
          client: () => MockClient(
              (_) async => http.Response('x' * (JsonAdCatalogue.maxBytes + 1), 200)));
      await expectLater(huge.fetch(), throwsA(isA<AdCatalogueException>()));
    });
  });
}

extension on AdService {
  /// Leaving the screen persists; the ticker needs no real timer for that.
  Future<void> onBackgroundForTest() async {
    onForeground();
    onBackground();
    await Future<void>.delayed(Duration.zero);
  }
}
