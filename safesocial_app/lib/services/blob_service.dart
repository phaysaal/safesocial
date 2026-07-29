import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../crypto/blob.dart';
import '../crypto/mailbox.dart';
import '../crypto/spheres_crypto.dart';
import 'debug_log_service.dart';

/// Uploads and fetches encrypted media blobs.
///
/// Media is encrypted, split into chunks and stored out of band, so a photo no
/// longer has to fit inside a message and no longer has to be re-encrypted and
/// re-sent once per recipient. The message carries only a [BlobRef].
///
/// The blob address is derived from a fresh random seed rather than from the
/// content. Content-addressing would let the relay see that two people hold the
/// same image, which is exactly the kind of correlation this project is trying
/// not to leak.
class BlobService {
  static const _defaultRelayHost = 'relay.spheres.dev';
  static const _fallbackRelayHost = 'spheres-relay.phaysaal.workers.dev';

  /// Overridable so tests do not need a network.
  static Future<http.Response> Function(
    String method,
    Uri url,
    Map<String, String> headers,
    List<int>? body,
  )? transportOverride;

  final _log = DebugLogService();

  String _host(bool fallback) =>
      fallback ? _fallbackRelayHost : _defaultRelayHost;

  Future<http.Response> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) {
    final override = transportOverride;
    if (override != null) return override(method, url, headers, body);
    if (method == 'PUT') {
      return http.put(url, headers: headers, body: body);
    }
    return http.get(url, headers: headers);
  }

  /// Encrypt [bytes], upload every chunk, and return the reference to embed.
  ///
  /// Returns null if any chunk fails — a partially uploaded blob is worse than
  /// none, because the reference would look valid and never resolve.
  Future<BlobRef?> upload({
    required Uint8List bytes,
    required String mimeType,
    String? thumbnail,
  }) async {
    final seed = SpheresCrypto.randomBytes(32);
    final mailbox = await Mailbox.fromLocalSecret(
      secret: base64Url.encode(seed),
      purpose: 'blob',
    );

    final chunks = BlobCrypto.split(bytes);
    if (chunks.length > 512) {
      _log.error('Blob', 'Media too large: ${chunks.length} chunks');
      return null;
    }

    for (var i = 0; i < chunks.length; i++) {
      final ciphertext = await BlobCrypto.encryptChunk(
        seed: seed,
        address: mailbox.id,
        index: i,
        chunkCount: chunks.length,
        plaintext: chunks[i],
      );
      final payload = base64Encode(ciphertext);

      if (!await _putChunk(mailbox, i, payload)) {
        _log.error('Blob', 'Upload failed at chunk $i of ${chunks.length}');
        return null;
      }
    }

    _log.info('Blob',
        'Uploaded ${bytes.length ~/ 1024}KB as ${chunks.length} chunk(s)');

    return BlobRef(
      address: mailbox.id,
      seed: seed,
      chunkCount: chunks.length,
      length: bytes.length,
      mimeType: mimeType,
      thumbnail: thumbnail,
    );
  }

  Future<bool> _putChunk(Mailbox mailbox, int index, String payload) async {
    final path = '/blob/${mailbox.id}/$index';
    for (final fallback in [false, true]) {
      try {
        final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
        final response = await _send(
          'PUT',
          Uri.parse('https://${_host(fallback)}$path'),
          headers: {
            'X-Spheres-Signature': mailbox.sign('PUT', path, payload, timestamp),
            'X-Spheres-Timestamp': timestamp,
          },
          body: utf8.encode(payload),
        );
        // 409 means the chunk is already there, which is success for our
        // purposes — a retried upload must not fail.
        if (response.statusCode == 200 || response.statusCode == 409) {
          return true;
        }
        _log.warn('Blob', 'Chunk $index rejected: ${response.statusCode}');
      } catch (e) {
        _log.warn('Blob', 'Chunk $index failed on ${_host(fallback)}: $e');
      }
    }
    return false;
  }

  /// Fetch and decrypt a blob, returning its plaintext bytes.
  Future<Uint8List?> download(BlobRef ref) async {
    final assembled = BytesBuilder();

    for (var i = 0; i < ref.chunkCount; i++) {
      final payload = await _getChunk(ref.address, i);
      if (payload == null) {
        _log.error('Blob', 'Missing chunk $i of ${ref.chunkCount}');
        return null;
      }

      try {
        assembled.add(await BlobCrypto.decryptChunk(
          seed: ref.seed,
          address: ref.address,
          index: i,
          chunkCount: ref.chunkCount,
          ciphertext: base64Decode(payload),
        ));
      } catch (e) {
        // A chunk that does not authenticate has been tampered with, or spliced
        // in from another blob. Refuse the whole thing.
        _log.error('Blob', 'Chunk $i failed authentication: $e');
        return null;
      }
    }

    final bytes = assembled.toBytes();
    if (bytes.length != ref.length) {
      _log.error('Blob',
          'Length mismatch: expected ${ref.length}, assembled ${bytes.length}');
      return null;
    }
    return bytes;
  }

  Future<String?> _getChunk(String address, int index) async {
    for (final fallback in [false, true]) {
      try {
        final response = await _send(
          'GET',
          Uri.parse('https://${_host(fallback)}/blob/$address/$index'),
        );
        if (response.statusCode == 200) return response.body;
      } catch (e) {
        _log.warn('Blob', 'Fetch failed on ${_host(fallback)}: $e');
      }
    }
    return null;
  }

  /// Download a blob and write it to a local file, caching by address.
  ///
  /// Cached under the blob address, so the same media is only fetched once even
  /// if it appears in several posts.
  Future<String?> materialise(BlobRef ref) async {
    final dir = await getApplicationDocumentsDirectory();
    final cache = Directory('${dir.path}/media');
    if (!cache.existsSync()) await cache.create(recursive: true);

    final extension = ref.isVideo ? 'mp4' : 'jpg';
    // The address is base64url, which can contain characters that are awkward
    // in filenames; hex-ish sanitising keeps it filesystem-safe.
    final safeName = ref.address.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final file = File('${cache.path}/$safeName.$extension');
    if (file.existsSync()) return file.path;

    final bytes = await download(ref);
    if (bytes == null) return null;

    await file.writeAsBytes(bytes);
    return file.path;
  }
}
