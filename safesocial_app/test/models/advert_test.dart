import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/advert.dart';
import 'package:spheres_app/services/ad_catalogue.dart';

/// The rules of the advert slot that do not need a clock: what a plan lets
/// the person turn off, what counts as a whole advert, and what a catalogue
/// document must look like.
void main() {
  group('the category choice', () {
    test('a fresh install has every category on', () {
      final c = AdChoice.everything();
      expect(c.on, AdCategory.ids);
      expect(c.plan, AdPlan.free);
    });

    test('the free plan refuses to go under ten and says so', () {
      var c = AdChoice.everything();
      final ids = AdCategory.all.map((c) => c.id).toList();
      for (final id in ids.take(ids.length - AdPlan.freeMinimum)) {
        c = c.set(id, false);
      }
      expect(c.on.length, AdPlan.freeMinimum);
      expect(c.canTurnOneOff, isFalse);
      expect(() => c.set(ids.last, false), throwsStateError);
      // Turning one back on makes room for another to go off.
      c = c.set(ids.first, true);
      expect(c.canTurnOneOff, isTrue);
      c = c.set(ids.last, false);
      expect(c.on.length, AdPlan.freeMinimum);
    });

    test('the paid plan may turn every category off', () {
      var c = AdChoice.everything(plan: AdPlan.paid);
      for (final id in AdCategory.ids) {
        c = c.set(id, false);
      }
      expect(c.on, isEmpty);
      expect(c.canTurnOneOff, isFalse);
    });

    test('back on the free plan, categories come on in list order up to the floor', () {
      var c = AdChoice.everything(plan: AdPlan.paid);
      for (final id in AdCategory.ids) {
        c = c.set(id, false);
      }
      c = c.set('pets', true);
      final free = c.withPlan(AdPlan.free);
      expect(free.on.length, AdPlan.freeMinimum);
      expect(free.on, contains('pets'));
      // The first nine of the fixed list, plus the one kept.
      final firstNine = AdCategory.all.take(9).map((c) => c.id);
      expect(free.on, containsAll(firstNine));
    });

    test('an unknown category id is refused, and ignored when stored', () {
      final c = AdChoice.everything();
      expect(() => c.set('crypto', true), throwsArgumentError);
      final stored = AdChoice.fromJson({'plan': 'free', 'on': ['books', 'crypto']});
      expect(stored.on, isNot(contains('crypto')));
      // A stored choice under the floor is brought up to it, not trusted.
      expect(stored.on.length, AdPlan.freeMinimum);
    });

    test('round-trips through JSON', () {
      final c = AdChoice.everything(plan: AdPlan.paid).set('books', false);
      final back = AdChoice.fromJson(c.toJson());
      expect(back.plan, AdPlan.paid);
      expect(back.on, c.on);
    });
  });

  group('an advert', () {
    final whole = {
      'id': 'a1',
      'category': 'books',
      'title': 'A book',
      'body': 'About things.',
      'sponsor': 'The Press',
      'link': 'https://example.org/book',
    };

    test('parses whole, with an http(s) link', () {
      final a = Advert.tryParse(whole)!;
      expect(a.id, 'a1');
      expect(a.link, Uri.parse('https://example.org/book'));
      expect(a.why, contains('Books and reading'));
      expect(Advert.tryParse(a.toJson())!.link, a.link);
    });

    test('is dropped when a field is missing, too long, or in an unknown category', () {
      expect(Advert.tryParse({...whole}..remove('title')), isNull);
      expect(Advert.tryParse({...whole, 'category': 'crypto'}), isNull);
      expect(Advert.tryParse({...whole, 'title': 'x' * 81}), isNull);
      expect(Advert.tryParse({...whole, 'sponsor': '  '}), isNull);
      expect(Advert.tryParse('not a map'), isNull);
    });

    test('a link that is not http(s) drops the whole advert', () {
      expect(Advert.tryParse({...whole, 'link': 'javascript:alert(1)'}), isNull);
      expect(Advert.tryParse({...whole, 'link': 'spheres://join?s=1'}), isNull);
      expect(Advert.tryParse({...whole, 'link': 'https://'}), isNull);
      // No link at all is fine.
      expect(Advert.tryParse({...whole}..remove('link'))!.link, isNull);
    });
  });

  group('a catalogue document', () {
    test('keeps whole adverts once each and drops the rest', () {
      final ads = JsonAdCatalogue.parse('''
        {"version": 1, "ads": [
          {"id": "a", "category": "books", "title": "A", "body": "", "sponsor": "S"},
          {"id": "a", "category": "music", "title": "Again", "body": "", "sponsor": "S"},
          {"id": "b", "category": "nope", "title": "B", "body": "", "sponsor": "S"},
          {"id": "c", "category": "music", "title": "C", "body": "", "sponsor": "S"},
          42
        ]}''');
      expect(ads.map((a) => a.id), ['a', 'c']);
      expect(ads.first.category, 'books');
    });

    test('refuses anything that is not a version 1 catalogue', () {
      expect(() => JsonAdCatalogue.parse('nonsense'), throwsA(isA<AdCatalogueException>()));
      expect(() => JsonAdCatalogue.parse('{"version": 2, "ads": []}'),
          throwsA(isA<AdCatalogueException>()));
      expect(() => JsonAdCatalogue.parse('{"version": 1}'),
          throwsA(isA<AdCatalogueException>()));
    });

    test('the operator\'s "no adverts" source offers none and never fails', () async {
      const none = NoAdverts();
      expect(none.offersAdverts, isFalse);
      expect(await none.fetch(), isEmpty);
    });
  });
}
