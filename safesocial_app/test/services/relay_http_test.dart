import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spheres_app/services/relay_service.dart';

void main() {
  const hosts = ['relay.example', 'fallback.example'];

  test('a host that cannot be resolved is skipped for the next one', () async {
    final tried = <String>[];
    final response = await relayHttp(hosts: hosts, (host) async {
      tried.add(host);
      if (host == 'relay.example') {
        throw const SocketException('Failed host lookup');
      }
      return http.Response('ok', 200);
    });
    expect(response.statusCode, 200);
    expect(tried, hosts);
  });

  test('a refused connection and a timeout move on as well', () async {
    final answers = <String, Object>{
      'a': http.ClientException('Connection refused'),
      'b': TimeoutException('slow'),
      'c': http.Response('late but here', 200),
    };
    final response = await relayHttp(hosts: ['a', 'b', 'c'], (host) async {
      final answer = answers[host]!;
      if (answer is http.Response) return answer;
      throw answer;
    });
    expect(response.body, 'late but here');
  });

  test('an HTTP status is an answer and never triggers the fallback', () async {
    final tried = <String>[];
    final response = await relayHttp(hosts: hosts, (host) async {
      tried.add(host);
      return http.Response('nope', 503);
    });
    expect(response.statusCode, 503);
    expect(tried, ['relay.example'], reason: 'the relay spoke; do not second-guess it');
  });

  test('when every host fails the last failure is what the caller sees', () async {
    expect(
      () => relayHttp(hosts: hosts, (host) async {
        throw SocketException('down: $host');
      }),
      throwsA(isA<SocketException>()
          .having((e) => e.message, 'message', 'down: fallback.example')),
    );
  });

  test('an unrelated error is not retried elsewhere', () async {
    final tried = <String>[];
    await expectLater(
      () => relayHttp(hosts: hosts, (host) async {
        tried.add(host);
        throw const FormatException('bad body');
      }),
      throwsA(isA<FormatException>()),
    );
    expect(tried, ['relay.example']);
  });
}
