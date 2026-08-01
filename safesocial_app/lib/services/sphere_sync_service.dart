import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'debug_log_service.dart';
import 'secure_store.dart';
import 'sphere_service.dart';

/// Filling in what a member missed, by asking another member.
///
/// The relay holds a copy of everything for a while, which covers the ordinary
/// case of being offline for a few hours. It does not cover being away longer
/// than the retention window, a mailbox trimmed because it filled up, joining
/// a sphere and wanting what came before, or any future bug that drops
/// something. In all of those the content still exists — on the phones of
/// everyone else in the sphere — and there was simply no way to ask for it.
///
/// So: keep the sealed envelopes we receive, tell a couple of peers which ones
/// we hold, and let them send back what we are missing.
///
/// Relaying somebody else's content is safe here without any new trust. An
/// envelope is signed by its author over both header and ciphertext and sealed
/// with the sphere key, and the receiving side already checks all of that. A
/// dishonest peer can withhold; it cannot forge, alter, or invent. That is why
/// the archive stores envelopes exactly as they arrived rather than re-sealing
/// them — we could not sign as their author, and should not be able to.
class SphereSyncService extends ChangeNotifier {
  static const _prefsPrefix = 'spheres_archive_';
  static const _prefsIndexKey = 'spheres_archive_index_v1';

  /// Envelopes offered in one digest, newest first.
  ///
  /// Bounded so a digest stays small; anything older converges over several
  /// rounds rather than in one.
  static const int digestSize = 300;

  /// Envelopes sent in one reply, and the ceiling on their combined size.
  ///
  /// The relay refuses bodies over 256 KB, and a reply that is too large to
  /// deliver helps nobody. Whatever does not fit goes in the next round.
  static const int maxItemsPerReply = 20;
  static const int maxReplyBytes = 128 * 1024;

  /// Peers asked per round. Two is enough: gossip converges in about log(n)
  /// rounds, and asking everyone would multiply traffic for no benefit.
  static const int peersPerRound = 2;

  final SphereService _spheres;
  final Random _random;

  SphereSyncService(this._spheres, {Random? random})
      : _random = random ?? Random();

  /// sphere id -> envelope id -> what we hold.
  final Map<String, Map<String, _Held>> _archive = {};

  /// How long to keep content for. The user's choice: a sphere remembers for
  /// as long as its most patient member does.
  Duration retention = const Duration(days: 30);

  /// Sends one sealed payload to one member. Supplied by the app.
  Future<bool> Function(String peerIdentityKey, String payload)? sendToPeer;

  /// Hands a recovered envelope back to whoever knows how to open it.
  Future<void> Function(String from, String sealed)? onRecovered;

  int heldIn(String sphereId) => _archive[sphereId]?.length ?? 0;

  /// Every envelope id we hold for a sphere.
  List<String> idsIn(String sphereId) =>
      (_archive[sphereId] ?? const <String, _Held>{}).keys.toList();

  bool holds(String sphereId, String envelopeId) =>
      _archive[sphereId]?.containsKey(envelopeId) ?? false;

  // ── Keeping ────────────────────────────────────────────────────────────────

  /// Remember an envelope so it can be offered to somebody who missed it.
  Future<void> remember({
    required String sphereId,
    required String envelopeId,
    required String sealed,
    DateTime? at,
  }) async {
    final held = _archive.putIfAbsent(sphereId, () => {});
    if (held.containsKey(envelopeId)) return;
    held[envelopeId] = _Held(sealed: sealed, at: at ?? DateTime.now());
    await _persist(sphereId);
  }

  /// Drop anything past its retention, and anything for a sphere we left.
  Future<void> prune() async {
    final live = _spheres.spheres.map((s) => s.id).toSet();
    final cutoff = DateTime.now().subtract(retention);

    for (final sphereId in _archive.keys.toList()) {
      if (!live.contains(sphereId)) {
        _archive.remove(sphereId);
        await SecureStore.instance.remove('$_prefsPrefix$sphereId');
        continue;
      }
      final held = _archive[sphereId]!;
      final before = held.length;
      held.removeWhere((_, h) => h.at.isBefore(cutoff));
      if (held.length != before) await _persist(sphereId);
    }
    await _persistIndex();
  }

  // ── Asking ─────────────────────────────────────────────────────────────────

  /// Ask a couple of peers what they have that we do not.
  ///
  /// Safe to call often: a digest is a few kilobytes and a peer with nothing to
  /// offer answers with nothing.
  Future<void> syncSphere(String sphereId) async {
    final send = sendToPeer;
    if (send == null) return;

    final peers = List<String>.from(_spheres.reachableMembers(sphereId))
      ..shuffle(_random);
    if (peers.isEmpty) return;

    final digest = _digestFor(sphereId);
    for (final peer in peers.take(peersPerRound)) {
      try {
        final sealed = await _spheres.sealContent(
          sphereId: sphereId,
          type: 'sphere_content',
          plaintext: jsonEncode({'type': 'sync_digest', 'have': digest}),
        );
        await send(peer, sealed);
      } catch (e) {
        // Usually a sphere we hold no current key for. Nothing to do but wait.
        DebugLogService().info('Sync', 'Could not ask a peer: $e');
      }
    }
  }

  Future<void> syncAll() async {
    for (final sphere in _spheres.spheres) {
      await syncSphere(sphere.id);
    }
  }

  List<String> _digestFor(String sphereId) {
    final held = _archive[sphereId];
    if (held == null || held.isEmpty) return const [];
    final ids = held.keys.toList()
      ..sort((a, b) => held[b]!.at.compareTo(held[a]!.at));
    return ids.take(digestSize).toList();
  }

  // ── Answering ──────────────────────────────────────────────────────────────

  /// Someone told us what they hold. Send back what they are missing.
  Future<void> handleDigest(
    String from,
    String sphereId,
    Map<String, dynamic> payload,
  ) async {
    final send = sendToPeer;
    if (send == null) return;
    if (_spheres.sphere(sphereId) == null) return;

    final theirs = (payload['have'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toSet();
    final held = _archive[sphereId];
    if (held == null || held.isEmpty) return;

    // Newest first: what somebody missed most recently is what they most want.
    final missing = held.entries
        .where((e) => !theirs.contains(e.key))
        .toList()
      ..sort((a, b) => b.value.at.compareTo(a.value.at));
    if (missing.isEmpty) return;

    final items = <String>[];
    var bytes = 0;
    for (final entry in missing.take(maxItemsPerReply)) {
      final size = entry.value.sealed.length;
      if (bytes + size > maxReplyBytes) break;
      items.add(entry.value.sealed);
      bytes += size;
    }
    if (items.isEmpty) return;

    try {
      final sealed = await _spheres.sealContent(
        sphereId: sphereId,
        type: 'sphere_content',
        plaintext: jsonEncode({'type': 'sync_items', 'items': items}),
      );
      await send(from, sealed);
      DebugLogService().info(
          'Sync', 'Sent ${items.length} missing item(s) to a peer');
    } catch (e) {
      DebugLogService().error('Sync', 'Could not answer a digest: $e');
    }
  }

  /// A peer sent back things we were missing.
  ///
  /// Each is handed to the ordinary inbound path, which verifies the author's
  /// signature, checks they were a member and decrypts — exactly as if it had
  /// arrived from them directly. Nothing here is trusted because a peer said so.
  Future<void> handleItems(
    String from,
    String sphereId,
    Map<String, dynamic> payload,
  ) async {
    final deliver = onRecovered;
    if (deliver == null) return;

    final items =
        (payload['items'] as List<dynamic>? ?? const []).whereType<String>();
    var recovered = 0;
    for (final sealed in items) {
      try {
        await deliver(from, sealed);
        recovered++;
      } catch (e) {
        DebugLogService().warn('Sync', 'Could not apply a recovered item: $e');
      }
    }
    if (recovered > 0) {
      DebugLogService()
          .info('Sync', 'Recovered $recovered item(s) from a peer');
      notifyListeners();
    }
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  Future<void> load() async {
    final store = SecureStore.instance;
    final index = await store.getStringList(_prefsIndexKey) ?? const [];
    for (final sphereId in index) {
      final raw = await store.getString('$_prefsPrefix$sphereId');
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _archive[sphereId] = decoded.map(
            (id, v) => MapEntry(id, _Held.fromJson(v as Map<String, dynamic>)));
      } catch (e) {
        DebugLogService().error('Sync', 'Could not read the archive: $e');
      }
    }
  }

  Future<void> _persist(String sphereId) async {
    final held = _archive[sphereId] ?? const <String, _Held>{};
    await SecureStore.instance.setString(
      '$_prefsPrefix$sphereId',
      jsonEncode(held.map((id, h) => MapEntry(id, h.toJson()))),
    );
    await _persistIndex();
  }

  Future<void> _persistIndex() => SecureStore.instance
      .setStringList(_prefsIndexKey, _archive.keys.toList());
}

class _Held {
  final String sealed;
  final DateTime at;

  const _Held({required this.sealed, required this.at});

  Map<String, dynamic> toJson() =>
      {'s': sealed, 'at': at.toIso8601String()};

  static _Held fromJson(Map<String, dynamic> json) => _Held(
        sealed: json['s'] as String,
        at: DateTime.parse(json['at'] as String),
      );
}
