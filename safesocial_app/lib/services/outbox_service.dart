import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'secure_store.dart';

import 'debug_log_service.dart';

/// How far along a queued message is.
enum OutboxState {
  /// Written down, not yet handed to the relay.
  pending,

  /// The relay accepted it. Not proof the recipient has it.
  sent,

  /// The recipient's device confirmed receipt.
  delivered,

  /// Gave up after [OutboxService.maxAttempts].
  failed,
}

/// One queued outbound message.
class OutboxEntry {
  /// Application-level message id, so a delivery receipt can be matched back.
  final String id;

  /// Contact this is addressed to (Ed25519 identity key, hex).
  final String peer;

  /// The sealed envelope, ready to transmit. Already encrypted — the outbox
  /// never holds plaintext.
  final String payload;

  final DateTime queuedAt;
  OutboxState state;
  int attempts;
  DateTime? lastAttemptAt;

  OutboxEntry({
    required this.id,
    required this.peer,
    required this.payload,
    required this.queuedAt,
    this.state = OutboxState.pending,
    this.attempts = 0,
    this.lastAttemptAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'peer': peer,
        'payload': payload,
        'queuedAt': queuedAt.toIso8601String(),
        'state': state.name,
        'attempts': attempts,
        'lastAttemptAt': lastAttemptAt?.toIso8601String(),
      };

  static OutboxEntry fromJson(Map<String, dynamic> json) {
    OutboxState state = OutboxState.pending;
    for (final candidate in OutboxState.values) {
      if (candidate.name == json['state']) state = candidate;
    }
    return OutboxEntry(
      id: json['id'] as String,
      peer: json['peer'] as String,
      payload: json['payload'] as String,
      queuedAt: DateTime.parse(json['queuedAt'] as String),
      state: state,
      attempts: json['attempts'] as int? ?? 0,
      lastAttemptAt: json['lastAttemptAt'] == null
          ? null
          : DateTime.parse(json['lastAttemptAt'] as String),
    );
  }
}

/// A durable queue for outbound messages.
///
/// Every message is written here *before* any network attempt and stays until
/// the relay accepts it. Previously `sendViaRelay`'s boolean result was
/// discarded, so a message composed while the socket was down rendered as sent
/// and was gone — the single largest cause of "messaging is unreliable".
///
/// Retries are driven by two things: a periodic tick, and a callback when a
/// room reconnects. Both are needed — the tick alone is too slow after a
/// network change, and the reconnect alone misses transient send failures.
class OutboxService extends ChangeNotifier {
  static const _prefsKey = 'spheres_outbox_v1';

  /// Give up after this many attempts, so a permanently unreachable peer does
  /// not retry forever.
  static const int maxAttempts = 12;

  static const Duration tickInterval = Duration(seconds: 15);

  final List<OutboxEntry> _entries = [];
  Timer? _timer;
  bool _flushing = false;

  /// Hands a payload to the transport. Returns true if the relay accepted it.
  Future<bool> Function(String peer, String payload)? send;

  List<OutboxEntry> get entries => List.unmodifiable(_entries);

  /// Entries still waiting to reach the relay.
  int get pendingCount =>
      _entries.where((e) => e.state == OutboxState.pending).length;

  OutboxState? stateOf(String messageId) {
    for (final entry in _entries) {
      if (entry.id == messageId) return entry.state;
    }
    return null;
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(tickInterval, (_) => flush());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Queue a sealed payload and try to send it immediately.
  Future<void> enqueue({
    required String id,
    required String peer,
    required String payload,
  }) async {
    if (_entries.any((e) => e.id == id)) return;

    _entries.add(OutboxEntry(
      id: id,
      peer: peer,
      payload: payload,
      queuedAt: DateTime.now(),
    ));
    await _persist();
    notifyListeners();

    await flush();
  }

  /// Attempt every pending entry once.
  ///
  /// Reentrancy-guarded: the periodic tick and a reconnect can fire together,
  /// and sending the same entry twice would surface as a duplicate message.
  Future<void> flush({String? onlyPeer}) async {
    if (_flushing || send == null) return;
    _flushing = true;

    try {
      var changed = false;
      for (final entry in List<OutboxEntry>.from(_entries)) {
        if (entry.state != OutboxState.pending) continue;
        if (onlyPeer != null && entry.peer != onlyPeer) continue;

        entry.attempts++;
        entry.lastAttemptAt = DateTime.now();

        final ok = await send!(entry.peer, entry.payload);
        if (ok) {
          entry.state = OutboxState.sent;
          changed = true;
        } else if (entry.attempts >= maxAttempts) {
          entry.state = OutboxState.failed;
          changed = true;
          DebugLogService().error(
            'Outbox',
            'Giving up on message ${entry.id} to ${entry.peer} after ${entry.attempts} attempts',
          );
        } else {
          changed = true;
        }
      }

      if (changed) {
        await _persist();
        notifyListeners();
      }
    } finally {
      _flushing = false;
    }
  }

  /// Mark a message confirmed by the recipient.
  Future<void> markDelivered(String messageId) async {
    for (final entry in _entries) {
      if (entry.id == messageId && entry.state != OutboxState.delivered) {
        entry.state = OutboxState.delivered;
        await _persist();
        notifyListeners();
        return;
      }
    }
  }

  /// Retry an entry that previously gave up.
  Future<void> retry(String messageId) async {
    for (final entry in _entries) {
      if (entry.id == messageId && entry.state == OutboxState.failed) {
        entry.state = OutboxState.pending;
        entry.attempts = 0;
        await _persist();
        notifyListeners();
        await flush();
        return;
      }
    }
  }

  /// Drop entries that are finished, keeping the queue from growing forever.
  Future<void> pruneCompleted({Duration keepFor = const Duration(days: 7)}) async {
    final cutoff = DateTime.now().subtract(keepFor);
    final before = _entries.length;
    _entries.removeWhere((e) =>
        (e.state == OutboxState.delivered || e.state == OutboxState.sent) &&
        e.queuedAt.isBefore(cutoff));
    if (_entries.length != before) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> removeForPeer(String peer) async {
    _entries.removeWhere((e) => e.peer == peer);
    await _persist();
    notifyListeners();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> load() async {
    final prefs = SecureStore.instance;
    final raw = await prefs.getString(_prefsKey);
    if (raw == null) return;

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _entries
        ..clear()
        ..addAll(list.map((e) => OutboxEntry.fromJson(e as Map<String, dynamic>)));

      // Anything left mid-flight when the app died is retried, not lost.
      for (final entry in _entries) {
        if (entry.state == OutboxState.pending && entry.attempts > 0) {
          entry.attempts = 0;
        }
      }

      if (pendingCount > 0) {
        DebugLogService()
            .info('Outbox', 'Restored $pendingCount unsent message(s)');
      }
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Outbox', 'Could not read outbox: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = SecureStore.instance;
    await prefs.setString(
      _prefsKey,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
