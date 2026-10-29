import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/sealed_box.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/models/abuse_report.dart';
import 'package:spheres_app/services/report_service.dart';
import 'package:spheres_app/services/terms.dart';

/// "Report to Spheres": the report is sealed on the phone to the operator's
/// key the relay publishes, so the relay stores a box it cannot open; the
/// reporter's own key is not in it; failures are said, never hidden.
void main() {
  tearDown(() => ReportService.transport = null);

  AbuseReport sample({String? text, List<String> media = const []}) => ReportService.build(
        reason: ReportReason.childSafety,
        note: 'Seen in a sphere I am in',
        subject: ReportSubject.post,
        subjectId: 'p1',
        author: 'a' * 64,
        authorName: 'Someone',
        text: text,
        media: media,
      );

  group('the report', () {
    test('carries what was chosen and nothing about the reporter', () {
      final r = sample(text: 'the words', media: ['AAAA', 'BBBB', 'CCCC', 'DDDD']);
      final j = r.toJson();
      expect(j['v'], 1);
      expect(j['reason'], 'childSafety');
      expect(j['subject'], 'post');
      expect(j['author'], 'a' * 64);
      expect(j['text'], 'the words');
      expect((j['media'] as List).length, AbuseReport.maxMedia, reason: 'at most three pictures');
      expect(j.keys, isNot(contains('reporter')));
      expect(AbuseReport.tryParse(jsonDecode(jsonEncode(j)))!.reason, ReportReason.childSafety);
    });

    test('without the content it carries no words and no pictures', () {
      final j = sample().toJson();
      expect(j.containsKey('text'), isFalse);
      expect(j.containsKey('media'), isFalse);
    });

    test('long notes and texts are cut, not refused', () {
      final r = ReportService.build(
          reason: ReportReason.other, note: 'n' * 5000, subject: ReportSubject.general, text: 't' * 9000);
      expect((r.toJson()['note'] as String).length, AbuseReport.maxNote);
      expect((r.toJson()['text'] as String).length, AbuseReport.maxText);
    });

    test('anything that is not a whole report does not parse', () {
      expect(AbuseReport.tryParse({'v': 1}), isNull);
      expect(AbuseReport.tryParse({'v': 2, 'id': 'x', 'reason': 'other', 'subject': 'post', 'at': '2026-01-01T00:00:00Z'}), isNull);
      expect(AbuseReport.tryParse('nope'), isNull);
    });
  });

  group('sending', () {
    test('seals to the operator key the relay publishes; only that key opens it', () async {
      final operator = await SpheresCrypto.newKeyExchangeKeyPair();
      final operatorHex = hex.encode((await operator.extractPublicKey()).bytes);
      String? posted;
      ReportService.transport = (call) async => _FakeRelay(operatorHex, (body) => posted = body).run(call);

      final error = await ReportService.send(sample(text: 'the words'));
      expect(error, isNull);
      final box = (jsonDecode(posted!) as Map)['box'] as String;
      expect(box, isNot(contains('the words')), reason: 'the relay sees ciphertext');

      final opened = await SealedBox.open(myKeyPair: operator, box: box);
      final report = AbuseReport.tryParse(jsonDecode(utf8.decode(opened!)))!;
      expect(report.text, 'the words');
      expect(report.reason, ReportReason.childSafety);

      final stranger = await SpheresCrypto.newKeyExchangeKeyPair();
      expect(await SealedBox.open(myKeyPair: stranger, box: box), isNull);
    });

    test('a relay without an operator key, a refusal, and no network are all said', () async {
      ReportService.transport = (call) async => _FakeRelay(null, (_) {}).run(call);
      expect(await ReportService.send(sample()), 'This relay does not take reports yet');

      final operator = await SpheresCrypto.newKeyExchangeKeyPair();
      final key = hex.encode((await operator.extractPublicKey()).bytes);
      ReportService.transport = (call) async => _FakeRelay(key, (_) {}, status: 429).run(call);
      expect(await ReportService.send(sample()), 'Too many reports from this phone today');

      ReportService.transport = (call) async => throw const SocketExceptionLike();
      expect(await ReportService.send(sample()), startsWith('Could not reach the relay'));
    });
  });

  group('the terms', () {
    test('are not agreed until agreed, and stay agreed', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await Terms.accepted(), isFalse);
      await Terms.accept();
      expect(await Terms.accepted(), isTrue);
    });
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

/// The relay's two answers: the root with the operator key, and /report.
class _FakeRelay {
  final String? key;
  final void Function(String body) onPost;
  final int status;
  _FakeRelay(this.key, this.onPost, {this.status = 200});

  Future<http.Response> run(Future<http.Response> Function(String host) call) async {
    // The service builds the request against a host; intercept by running it
    // against a host whose client is ours.
    return http.runWithClient(() => call('relay.test'), () => _client());
  }

  http.Client _client() => _MockClient(this);
}

class _MockClient extends http.BaseClient {
  final _FakeRelay relay;
  _MockClient(this.relay);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path == '/') {
      final body = jsonEncode({'service': 'Spheres Relay', 'report': relay.key});
      return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
    }
    if (request.method == 'POST' && request.url.path == '/report') {
      final body = await (request as http.Request).finalize().bytesToString();
      relay.onPost(body);
      return http.StreamedResponse(Stream.value(utf8.encode('{"id":"r1"}')), relay.status);
    }
    return http.StreamedResponse(const Stream.empty(), 404);
  }
}
