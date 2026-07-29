import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spheres_app/crypto/blob.dart';
import 'package:spheres_app/services/blob_service.dart';

/// An in-memory stand-in for the relay's blob endpoints, so these exercise the
/// real chunking and crypto without a network.
class _FakeRelay {
  final Map<String, String> chunks = {};
  int puts = 0;
  int gets = 0;

  /// Set to fail uploads from this chunk index onward.
  int? failFromIndex;

  Future<http.Response> handle(
    String method,
    Uri url,
    Map<String, String> headers,
    List<int>? body,
  ) async {
    final segments = url.pathSegments; // blob/<address>/<index>
    final key = '${segments[1]}/${segments[2]}';
    final index = int.parse(segments[2]);

    if (method == 'PUT') {
      puts++;
      if (failFromIndex != null && index >= failFromIndex!) {
        return http.Response('nope', 500);
      }
      // The relay refuses to overwrite an existing chunk.
      if (chunks.containsKey(key)) return http.Response('exists', 409);
      chunks[key] = utf8.decode(body!);
      return http.Response('OK', 200);
    }

    gets++;
    final chunk = chunks[key];
    return chunk == null
        ? http.Response('', 404)
        : http.Response(chunk, 200);
  }
}

void main() {
  late _FakeRelay relay;

  setUp(() {
    relay = _FakeRelay();
    BlobService.transportOverride = relay.handle;
  });

  tearDown(() => BlobService.transportOverride = null);

  Uint8List payloadOf(int length) =>
      Uint8List.fromList(List.generate(length, (i) => i % 251));

  group('round trip', () {
    test('a small blob survives upload and download', () async {
      final service = BlobService();
      final bytes = payloadOf(1024);

      final ref = await service.upload(bytes: bytes, mimeType: 'image/jpeg');

      expect(ref, isNotNull);
      expect(ref!.chunkCount, 1);
      expect(await service.download(ref), equals(bytes));
    });

    test('a blob larger than one chunk is split and reassembled', () async {
      final service = BlobService();
      final bytes = payloadOf(kBlobChunkBytes * 3 + 17);

      final ref = await service.upload(bytes: bytes, mimeType: 'image/jpeg');

      expect(ref!.chunkCount, 4);
      expect(relay.puts, 4);
      expect(await service.download(ref), equals(bytes));
    });

    test('an empty blob is handled', () async {
      final service = BlobService();
      final ref = await service.upload(bytes: Uint8List(0), mimeType: 'image/jpeg');

      expect(ref!.chunkCount, 1);
      expect(await service.download(ref), isEmpty);
    });
  });

  group('what the relay can see', () {
    test('stored chunks do not contain the plaintext', () async {
      final service = BlobService();
      final secret = utf8.encode('a recognisable secret string');
      final bytes = Uint8List.fromList(secret);

      await service.upload(bytes: bytes, mimeType: 'image/jpeg');

      for (final stored in relay.chunks.values) {
        expect(utf8.decode(base64Decode(stored), allowMalformed: true),
            isNot(contains('recognisable')));
      }
    });

    test('the same bytes uploaded twice get different addresses', () async {
      final service = BlobService();
      final bytes = payloadOf(2048);

      final first = await service.upload(bytes: bytes, mimeType: 'image/jpeg');
      final second = await service.upload(bytes: bytes, mimeType: 'image/jpeg');

      // Content-addressing would let the operator see that two people hold the
      // same image. Addresses are derived from a fresh random seed instead.
      expect(first!.address, isNot(second!.address));
    });
  });

  group('integrity', () {
    test('a tampered chunk is refused', () async {
      final service = BlobService();
      final ref =
          await service.upload(bytes: payloadOf(2048), mimeType: 'image/jpeg');

      final key = relay.chunks.keys.first;
      final corrupted = base64Decode(relay.chunks[key]!);
      corrupted[0] ^= 0x01;
      relay.chunks[key] = base64Encode(corrupted);

      expect(await service.download(ref!), isNull);
    });

    test('chunks cannot be reordered', () async {
      final service = BlobService();
      final ref = await service.upload(
          bytes: payloadOf(kBlobChunkBytes * 2), mimeType: 'image/jpeg');

      final a = '${ref!.address}/0';
      final b = '${ref.address}/1';
      final swap = relay.chunks[a];
      relay.chunks[a] = relay.chunks[b]!;
      relay.chunks[b] = swap!;

      // Each chunk is bound to its index as associated data.
      expect(await service.download(ref), isNull);
    });

    test('a chunk from another blob cannot be spliced in', () async {
      final service = BlobService();
      final victim =
          await service.upload(bytes: payloadOf(1024), mimeType: 'image/jpeg');
      final other =
          await service.upload(bytes: payloadOf(1024), mimeType: 'image/jpeg');

      relay.chunks['${victim!.address}/0'] =
          relay.chunks['${other!.address}/0']!;

      expect(await service.download(victim), isNull);
    });

    test('a missing chunk fails rather than returning a partial file', () async {
      final service = BlobService();
      final ref = await service.upload(
          bytes: payloadOf(kBlobChunkBytes * 2), mimeType: 'image/jpeg');

      relay.chunks.remove('${ref!.address}/1');

      expect(await service.download(ref), isNull);
    });
  });

  group('upload failure', () {
    test('a failed chunk yields no reference at all', () async {
      final service = BlobService();
      relay.failFromIndex = 2;

      final ref = await service.upload(
          bytes: payloadOf(kBlobChunkBytes * 3), mimeType: 'image/jpeg');

      // A partially uploaded blob is worse than none: the reference would look
      // valid and never resolve.
      expect(ref, isNull);
    });

    test('a retried upload tolerates chunks that already exist', () async {
      final service = BlobService();
      final bytes = payloadOf(1024);

      final ref = await service.upload(bytes: bytes, mimeType: 'image/jpeg');
      // Re-PUT the same chunk; the relay answers 409, which must not fail.
      final again = await service.upload(bytes: bytes, mimeType: 'image/jpeg');

      expect(ref, isNotNull);
      expect(again, isNotNull);
    });
  });

  group('references', () {
    test('encode and decode round trip', () async {
      final service = BlobService();
      final ref = await service.upload(
        bytes: payloadOf(512),
        mimeType: 'image/jpeg',
        thumbnail: 'data:image/jpeg;base64,AAAA',
      );

      final decoded = BlobRef.tryDecode(ref!.encode());

      expect(decoded, isNotNull);
      expect(decoded!.address, ref.address);
      expect(decoded.seed, ref.seed);
      expect(decoded.chunkCount, ref.chunkCount);
      expect(decoded.length, ref.length);
      expect(decoded.mimeType, 'image/jpeg');
      expect(decoded.thumbnail, 'data:image/jpeg;base64,AAAA');
    });

    test('a malformed reference decodes to null rather than throwing', () {
      expect(BlobRef.tryDecode('spheres-blob:not-base64!!'), isNull);
      expect(BlobRef.tryDecode('/local/path/photo.jpg'), isNull);
      expect(BlobRef.tryDecode('data:image/jpeg;base64,AAAA'), isNull);
    });

    test('video refs are recognised', () async {
      final service = BlobService();
      final ref = await service.upload(
          bytes: payloadOf(256), mimeType: 'video/mp4');

      expect(BlobRef.tryDecode(ref!.encode())!.isVideo, isTrue);
    });
  });
}
