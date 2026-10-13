import 'dart:convert';
import 'dart:typed_data';

import '../crypto/spheres_crypto.dart';

/// A picture that waits for the people in it.
///
/// Lives in a post's `payload['locked']`, one entry per media index. The
/// media reference in the post carries no key. The key is sealed to each
/// tagged person (so they can see what they are being asked about) and, cut
/// into one share per tagged person, each share sealed to its person. A
/// tagged person releases their share to the sphere as a `media_release`
/// item; when every share is in, anyone can join them back into the key and
/// open the picture. Until then the rest of the sphere sees a blurred frame
/// and the names still waiting. This is arithmetic, not policy: a member who
/// is not tagged holds nothing that opens the blob before the last yes.
class MediaLock {
  final Map<int, LockedItem> items;
  const MediaLock(this.items);

  static MediaLock? fromPayload(Map<String, dynamic>? payload) {
    final raw = payload?['locked'];
    if (raw is! Map || raw.isEmpty) return null;
    final items = <int, LockedItem>{};
    raw.forEach((k, v) {
      final i = int.tryParse('$k');
      if (i != null && v is Map) items[i] = LockedItem.fromJson(v.cast<String, dynamic>());
    });
    return items.isEmpty ? null : MediaLock(items);
  }

  Map<String, dynamic> toJson() => {for (final e in items.entries) '${e.key}': e.value.toJson()};

  LockedItem? operator [](int index) => items[index];

  /// Everyone named in any item.
  Set<String> get tags => {for (final i in items.values) ...i.tags};

  MediaLock withItem(int index, LockedItem item) => MediaLock({...items, index: item});
}

/// The sealed keys for one tagged person: the whole media key, and their share.
class SealedKeys {
  final String seed;
  final String share;
  const SealedKeys({required this.seed, required this.share});
  Map<String, dynamic> toJson() => {'seed': seed, 'share': share};
}

class LockedItem {
  final Map<String, SealedKeys> keys;

  /// Shares released so far, base64, by the identity key that released them.
  final Map<String, String> released;

  const LockedItem({required this.keys, this.released = const {}});

  static LockedItem fromJson(Map<String, dynamic> json) {
    final keys = <String, SealedKeys>{};
    final rawKeys = json['keys'];
    if (rawKeys is Map) {
      rawKeys.forEach((k, v) {
        if (k is String && v is Map && v['seed'] is String && v['share'] is String) {
          keys[k] = SealedKeys(seed: v['seed'] as String, share: v['share'] as String);
        }
      });
    }
    final released = <String, String>{};
    final rawReleased = json['released'];
    if (rawReleased is Map) {
      rawReleased.forEach((k, v) {
        if (k is String && v is String && keys.containsKey(k)) released[k] = v;
      });
    }
    return LockedItem(keys: keys, released: released);
  }

  Map<String, dynamic> toJson() => {
        'keys': {for (final e in keys.entries) e.key: e.value.toJson()},
        if (released.isNotEmpty) 'released': released,
      };

  Set<String> get tags => keys.keys.toSet();
  Set<String> get waiting => tags.difference(released.keys.toSet());
  bool get complete => keys.isNotEmpty && waiting.isEmpty;
  bool hasReleased(String who) => released.containsKey(who);

  /// The media key, once every share is in; null before.
  Uint8List? get seed => complete ? join([for (final t in tags) base64Decode(released[t]!)]) : null;

  LockedItem withRelease(String who, String share) =>
      LockedItem(keys: keys, released: {...released, who: share});

  /// Cut [seed] into [count] shares that XOR back to it: every share is
  /// needed, and any subset short of all of them says nothing about the key.
  static List<Uint8List> split(Uint8List seed, int count) {
    if (count < 1) throw ArgumentError('at least one share');
    final shares = <Uint8List>[for (var i = 1; i < count; i++) SpheresCrypto.randomBytes(seed.length)];
    final last = Uint8List.fromList(seed);
    for (final s in shares) {
      for (var b = 0; b < last.length; b++) {
        last[b] ^= s[b];
      }
    }
    return [...shares, last];
  }

  static Uint8List join(List<Uint8List> shares) {
    final out = Uint8List.fromList(shares.first);
    for (final s in shares.skip(1)) {
      if (s.length != out.length) throw ArgumentError('shares differ in length');
      for (var b = 0; b < out.length; b++) {
        out[b] ^= s[b];
      }
    }
    return out;
  }
}
