import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/advert.dart';

/// Where the adverts come from. The whole catalogue is fetched, every
/// category, so that whoever serves it learns nothing about which categories
/// this phone keeps on; the pick happens in [AdService], on the device.
abstract class AdCatalogue {
  /// Every advert on offer. Throws when the source cannot be reached, so the
  /// caller can say so instead of showing an empty slot as if that were the
  /// state of the world.
  Future<List<Advert>> fetch();

  /// Whether this source could ever return an advert. False for [NoAdverts].
  bool get offersAdverts;
}

/// The operator is not showing adverts. This is a decision, not a stub: the
/// framework is in place and Settings says in plain words that none are shown.
class NoAdverts implements AdCatalogue {
  const NoAdverts();

  @override
  bool get offersAdverts => false;

  @override
  Future<List<Advert>> fetch() async => const [];
}

/// A catalogue published as one JSON document:
///
/// ```json
/// {"version": 1, "ads": [
///   {"id": "a1", "category": "books", "title": "...", "body": "...",
///    "sponsor": "...", "link": "https://..."}
/// ]}
/// ```
///
/// Entries that are not whole adverts in a known category are dropped
/// (`Advert.tryParse`). The request carries no identifier, no cookie and
/// nothing about the phone beyond what any HTTP request says.
class JsonAdCatalogue implements AdCatalogue {
  final Uri url;
  final http.Client Function() _client;

  /// The document is capped so a misbehaving host cannot fill memory.
  static const maxBytes = 256 * 1024;

  JsonAdCatalogue(this.url, {http.Client Function()? client})
      : _client = client ?? http.Client.new;

  @override
  bool get offersAdverts => true;

  @override
  Future<List<Advert>> fetch() async {
    final client = _client();
    try {
      final response = await client
          .get(url, headers: const {'accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw AdCatalogueException('Catalogue answered ${response.statusCode}');
      }
      if (response.bodyBytes.length > maxBytes) {
        throw AdCatalogueException('Catalogue larger than $maxBytes bytes');
      }
      return parse(response.body);
    } finally {
      client.close();
    }
  }

  /// Parse a catalogue document. Public for tests and for a bundled file.
  static List<Advert> parse(String body) {
    final Object? doc;
    try {
      doc = jsonDecode(body);
    } catch (e) {
      throw AdCatalogueException('Catalogue is not JSON: $e');
    }
    if (doc is! Map || doc['version'] != 1) {
      throw AdCatalogueException('Catalogue has no version 1 header');
    }
    final raw = doc['ads'];
    if (raw is! List) throw AdCatalogueException('Catalogue has no ads list');
    final seen = <String>{};
    final ads = <Advert>[];
    for (final entry in raw) {
      final ad = Advert.tryParse(entry);
      if (ad != null && seen.add(ad.id)) ads.add(ad);
    }
    return ads;
  }
}

class AdCatalogueException implements Exception {
  final String message;
  AdCatalogueException(this.message);
  @override
  String toString() => message;
}
