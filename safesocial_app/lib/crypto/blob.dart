import 'dart:convert';
import 'dart:typed_data';

import 'spheres_crypto.dart';

/// How large a plaintext chunk may be.
///
/// Sized so that the ciphertext, once base64-encoded for transport, stays
/// comfortably under both the relay's body cap and a Durable Object storage
/// value (128 KiB).
const int kBlobChunkBytes = 48 * 1024;

/// Everything needed to fetch and open one media blob.
///
/// This travels *inside* a sealed envelope, so the key never reaches the relay.
/// The relay only ever sees the address and encrypted chunks.
///
/// Media used to be inlined into the message as a base64 data URI, which meant
/// a photo counted against the message size cap and had to be re-sent to every
/// recipient. Now the bytes are uploaded once and the message carries this
/// reference plus a small thumbnail.
class BlobRef {
  static const String scheme = 'spheres-blob:';
  static const int version = 1;

  /// Relay address for the blob — an Ed25519 public key derived from [seed].
  final String address;

  /// Secret the address and content key are derived from. Possession of this
  /// is what authorises reading; it never leaves a sealed envelope.
  final Uint8List seed;

  final int chunkCount;

  /// Total plaintext length, so a truncated download is detectable.
  final int length;

  final String mimeType;

  /// Small inline preview so a feed renders before any blob is fetched.
  /// Null for media we cannot thumbnail (video — there is no frame extractor
  /// in the dependency set).
  final String? thumbnail;

  const BlobRef({
    required this.address,
    required this.seed,
    required this.chunkCount,
    required this.length,
    required this.mimeType,
    required this.thumbnail,
  });

  bool get isVideo => mimeType.startsWith('video/');

  String encode() => '$scheme${base64Url.encode(utf8.encode(jsonEncode({
        'v': version,
        'a': address,
        's': base64Url.encode(seed),
        'c': chunkCount,
        'l': length,
        'm': mimeType,
        if (thumbnail != null) 't': thumbnail,
      })))}';

  static bool looksLikeRef(String value) => value.startsWith(scheme);

  /// Returns null rather than throwing: a malformed reference should degrade
  /// to "no media", not take down the message that carried it.
  static BlobRef? tryDecode(String value) {
    if (!looksLikeRef(value)) return null;
    try {
      final json = jsonDecode(
        utf8.decode(base64Url.decode(value.substring(scheme.length))),
      ) as Map<String, dynamic>;

      if (json['v'] != version) return null;

      return BlobRef(
        address: json['a'] as String,
        seed: Uint8List.fromList(base64Url.decode(json['s'] as String)),
        chunkCount: json['c'] as int,
        length: json['l'] as int,
        mimeType: json['m'] as String,
        thumbnail: json['t'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Chunked authenticated encryption for media.
class BlobCrypto {
  const BlobCrypto._();

  static const _infoContentKey = 'spheres-blob-key-v1';
  static const _infoNoncePrefix = 'spheres-blob-nonce-v1';

  static Future<Uint8List> contentKey(Uint8List seed) =>
      SpheresCrypto.hkdf(secret: seed, info: _infoContentKey);

  /// Nonce for one chunk: a per-blob prefix with the chunk index appended.
  ///
  /// Unique per (blob, chunk) because the content key is unique per blob, and
  /// the index is also bound as associated data so chunks cannot be reordered
  /// or spliced between blobs.
  static Future<Uint8List> _nonceFor(Uint8List seed, int index) async {
    final prefix = await SpheresCrypto.hkdf(secret: seed, info: _infoNoncePrefix);
    final nonce = Uint8List(SpheresCrypto.nonceLength)
      ..setRange(0, SpheresCrypto.nonceLength - 8,
          prefix.sublist(0, SpheresCrypto.nonceLength - 8));
    final view = ByteData.sublistView(nonce, SpheresCrypto.nonceLength - 8);
    view.setUint64(0, index);
    return nonce;
  }

  static Uint8List _aad(String address, int index, int chunkCount) =>
      Uint8List.fromList(utf8.encode('$address|$index|$chunkCount'));

  static Future<Uint8List> encryptChunk({
    required Uint8List seed,
    required String address,
    required int index,
    required int chunkCount,
    required List<int> plaintext,
  }) async =>
      SpheresCrypto.encrypt(
        key: await contentKey(seed),
        nonce: await _nonceFor(seed, index),
        plaintext: plaintext,
        aad: _aad(address, index, chunkCount),
      );

  static Future<Uint8List> decryptChunk({
    required Uint8List seed,
    required String address,
    required int index,
    required int chunkCount,
    required List<int> ciphertext,
  }) async =>
      SpheresCrypto.decrypt(
        key: await contentKey(seed),
        nonce: await _nonceFor(seed, index),
        ciphertextWithMac: ciphertext,
        aad: _aad(address, index, chunkCount),
      );

  /// Split [bytes] into chunk-sized slices.
  static List<Uint8List> split(Uint8List bytes) {
    final chunks = <Uint8List>[];
    for (var offset = 0; offset < bytes.length; offset += kBlobChunkBytes) {
      final end = (offset + kBlobChunkBytes).clamp(0, bytes.length);
      chunks.add(Uint8List.sublistView(bytes, offset, end));
    }
    return chunks.isEmpty ? [Uint8List(0)] : chunks;
  }
}
