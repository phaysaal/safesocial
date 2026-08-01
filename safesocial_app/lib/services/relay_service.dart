import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/mailbox.dart';
import 'debug_log_service.dart';
import 'relay_config.dart';

/// Whether a channel is usable right now.
enum RelayConnectionState { disconnected, connecting, connected }

/// Per-channel connection bookkeeping.
class _Conn {
  final Mailbox mailbox;
  WebSocketChannel? channel;
  RelayConnectionState state = RelayConnectionState.connecting;

  /// Set when the app closes the socket on purpose, so onDone does not
  /// resurrect it. Without this, disconnecting a blocked contact or leaving a
  /// group reconnected five seconds later, forever.
  bool closedIntentionally = false;

  /// Consecutive failed attempts, for backoff.
  int attempt = 0;

  Timer? retryTimer;

  /// Real-time frames that arrived while the offline mailbox was being
  /// fetched, held back so ordering is preserved.
  final List<String> buffer = [];
  bool syncing = true;

  /// When this connection last produced any evidence of being alive.
  ///
  /// A WebSocket can stop delivering without ever closing: a NAT that drops an
  /// idle mapping, a network handover, a relay that let the socket go. Nothing
  /// tells the client, `onDone` never fires, and the app sits there believing
  /// it is connected while messages pile up in a mailbox it is no longer
  /// reading.
  DateTime lastActivity = DateTime.now();

  _Conn(this.mailbox);
}

/// Client for the v2 relay protocol.
///
/// Addresses are Ed25519 public keys derived from a secret the participants
/// share, and every operation is signed with the matching private key. The
/// relay therefore cannot compute an address from public keys, cannot map
/// traffic onto the social graph, and cannot be convinced by a throwaway
/// keypair that it should hand over someone else's mail.
class RelayService extends ChangeNotifier {

  static const Duration _baseRetryDelay = Duration(seconds: 2);
  static const Duration _maxRetryDelay = Duration(minutes: 2);

  /// Payloads are padded up to the next bucket, so the operator learns a size
  /// class rather than an exact length.
  static const List<int> _paddingBuckets = [512, 2048, 8192, 32768, 131072];

  final Map<String, _Conn> _conns = {};
  final _log = DebugLogService();
  final Random _jitter = Random();

  /// Every live client, so one check can cover them all. There is a relay
  /// client per purpose — chat, feed, calls and so on — and a stale socket on
  /// any of them is equally invisible.
  static final Set<RelayService> _all = {};

  /// How long a connection may go quiet before we check it is really there.
  static const Duration idleBefore = Duration(minutes: 2);

  Timer? _watchdog;

  /// Ask every client to check its quiet connections.
  static Future<void> verifyAll() async {
    for (final service in _all.toList()) {
      await service.verifyIdleConnections();
    }
  }

  /// Prove a quiet connection is still delivering, and repair it if not.
  ///
  /// The check is evidence-based rather than a guess: fetch the mailbox over
  /// HTTP, which does not depend on the socket at all. If anything was waiting
  /// there, the socket demonstrably failed to deliver it, so it is replaced.
  Future<void> verifyIdleConnections() async {
    final now = DateTime.now();
    for (final entry in _conns.entries.toList()) {
      final conn = entry.value;
      if (conn.state != RelayConnectionState.connected) continue;
      if (conn.syncing) continue;
      if (now.difference(conn.lastActivity) < idleBefore) continue;

      final host = _host(false);
      final path = '/mbx/${conn.mailbox.id}';
      final recovered =
          await _syncMailbox(host, path, conn.mailbox, entry.key);
      conn.lastActivity = DateTime.now();

      if (recovered > 0) {
        _log.warn(
          'Relay',
          'A quiet connection had $recovered message(s) waiting; '
          'replacing it',
        );
        final mailbox = conn.mailbox;
        conn.closedIntentionally = true;
        conn.retryTimer?.cancel();
        try {
          await conn.channel?.sink.close();
        } catch (_) {}
        _conns.remove(entry.key);
        await connectMailbox(entry.key, mailbox);
      }
    }
  }

  void Function(String channelKey, String payload)? onMessageReceived;

  /// Called whenever a channel becomes usable, so queued work can be flushed.
  void Function(String channelKey)? onConnected;

  // The host is user-selectable so the relay operator is a choice; see
  // RelayConfig. Falling back only makes sense for the default deployment —
  // a self-hosted instance has no second host to try.
  String _host(bool isFallback) => isFallback
      ? (RelayConfig.primaryHost == RelayConfig.defaultHost
          ? RelayConfig.fallbackHost
          : RelayConfig.primaryHost)
      : RelayConfig.primaryHost;

  RelayConnectionState stateFor(String channelKey) =>
      _conns[channelKey]?.state ?? RelayConnectionState.disconnected;

  bool isConnected(String channelKey) =>
      _conns[channelKey]?.state == RelayConnectionState.connected;

  void _setState(String key, RelayConnectionState state) {
    final conn = _conns[key];
    if (conn == null || conn.state == state) return;
    conn.state = state;
    notifyListeners();
  }

  // -- Sealed mailboxes -------------------------------------------------------

  /// Open a channel on [mailbox], identified locally by [channelKey].
  ///
  /// [channelKey] is only a local handle (usually a contact's public key); it
  /// never reaches the relay.
  Future<void> connectMailbox(
    String channelKey,
    Mailbox mailbox, {
    bool isFallback = false,
  }) async {
    // Claim the slot before the first await. The previous version checked for
    // an existing channel at the top but only recorded one after
    // `await channel.ready`, so two rapid calls opened two sockets and the
    // second wiped the first's buffered messages.
    final existing = _conns[channelKey];
    if (existing != null && existing.state != RelayConnectionState.disconnected) {
      return;
    }

    final conn = _Conn(mailbox);
    _conns[channelKey] = conn;
    _all.add(this);
    _watchdog ??= Timer.periodic(idleBefore, (_) => verifyIdleConnections());
    _setState(channelKey, RelayConnectionState.connecting);

    final host = _host(isFallback);
    final path = '/mbx/${mailbox.id}';
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final signature = mailbox.sign('WS', path, '', timestamp);
    final wsUrl = 'wss://$host$path?ts=$timestamp&sig=$signature';

    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      conn.channel = channel;

      try {
        await channel.ready;
      } catch (e) {
        conn.channel = null;
        _log.error('Relay', 'WebSocket handshake failed: $e');
        if (!isFallback) {
          _conns.remove(channelKey);
          return connectMailbox(channelKey, mailbox, isFallback: true);
        }
        _scheduleRetry(channelKey, mailbox, isFallback);
        return;
      }

      conn.attempt = 0;
      _attempts.remove(channelKey);

      channel.stream.listen(
        (data) {
          conn.lastActivity = DateTime.now();
          final payload = _unpad(data as String);
          if (payload == null) return;
          if (conn.syncing) {
            conn.buffer.add(payload);
          } else {
            onMessageReceived?.call(channelKey, payload);
          }
        },
        onError: (e) => _log.error('Relay', 'WebSocket stream error: $e'),
        onDone: () {
          conn.channel = null;
          _setState(channelKey, RelayConnectionState.disconnected);
          if (conn.closedIntentionally) {
            _conns.remove(channelKey);
            return;
          }
          _scheduleRetry(channelKey, mailbox, isFallback);
        },
      );

      // Drain the offline mailbox before releasing buffered live frames, so
      // the caller sees them in order.
      await _syncMailbox(host, path, mailbox, channelKey);

      conn.syncing = false;
      if (conn.buffer.isNotEmpty) {
        for (final msg in conn.buffer) {
          onMessageReceived?.call(channelKey, msg);
        }
        conn.buffer.clear();
      }

      _setState(channelKey, RelayConnectionState.connected);
      onConnected?.call(channelKey);
    } catch (e) {
      _log.error('Relay', 'Failed to connect: $e');
      _scheduleRetry(channelKey, mailbox, isFallback);
    }
  }

  /// Reconnect after a delay that grows with consecutive failures.
  ///
  /// Jittered so a relay restart does not bring every client back at once.
  /// Attempts per channel, kept outside the connection because reconnecting
  /// replaces it — without this the counter reset every time and the backoff
  /// never grew, so a channel that could not connect hammered the relay every
  /// couple of seconds forever.
  final Map<String, int> _attempts = {};

  void _scheduleRetry(String channelKey, Mailbox mailbox, bool isFallback) {
    final conn = _conns[channelKey];
    if (conn == null || conn.closedIntentionally) return;

    conn.attempt = (_attempts[channelKey] ?? 0) + 1;
    _attempts[channelKey] = conn.attempt;
    final backoffMs = _baseRetryDelay.inMilliseconds * (1 << (conn.attempt - 1));
    final cappedMs = backoffMs.clamp(
      _baseRetryDelay.inMilliseconds,
      _maxRetryDelay.inMilliseconds,
    );
    final delay = Duration(milliseconds: cappedMs + _jitter.nextInt(1000));

    _setState(channelKey, RelayConnectionState.disconnected);
    _log.info('Relay',
        'Reconnecting $channelKey in ${delay.inSeconds}s (attempt ${conn.attempt})');

    conn.retryTimer?.cancel();
    conn.retryTimer = Timer(delay, () {
      if (conn.closedIntentionally) return;
      _conns.remove(channelKey);
      // Always come back to the primary. Failing over is for one attempt, not
      // for good: retrying the fallback forever left a channel that blipped
      // once permanently stranded on a host it could not reach, with no
      // messages in or out until the app was restarted.
      connectMailbox(channelKey, mailbox);
    });
  }

  /// Fetch anything waiting in the mailbox, returning how many were taken.
  ///
  /// The count is what makes a liveness check meaningful: messages found here
  /// on a supposedly connected socket are messages that socket failed to
  /// deliver.
  Future<int> _syncMailbox(
    String host,
    String path,
    Mailbox mailbox,
    String channelKey,
  ) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final signature = mailbox.sign('GET', '$path/sync', '', timestamp);

      final response = await http.get(
        Uri.parse('https://$host$path/sync'),
        headers: {
          'X-Spheres-Signature': signature,
          'X-Spheres-Timestamp': timestamp,
        },
      );

      if (response.statusCode == 401) {
        _log.error('Relay', 'Mailbox sync rejected: unauthorized');
        return 0;
      }
      if (response.statusCode != 200) return 0;

      final pending = jsonDecode(response.body) as List<dynamic>;
      if (pending.isEmpty) return 0;

      final processed = <String>[];
      for (final msg in pending) {
        try {
          final payload = _unpad(msg['data'] as String);
          if (payload != null) onMessageReceived?.call(channelKey, payload);
          processed.add(msg['id'] as String);
        } catch (e) {
          _log.error('Relay', 'Could not process queued message: $e');
        }
      }

      if (processed.isEmpty) return 0;

      final body = jsonEncode({'ids': processed});
      final ackTs = DateTime.now().millisecondsSinceEpoch.toString();
      await http.post(
        Uri.parse('https://$host$path/ack'),
        headers: {
          'Content-Type': 'application/json',
          'X-Spheres-Signature': mailbox.sign('POST', '$path/ack', body, ackTs),
          'X-Spheres-Timestamp': ackTs,
        },
        body: body,
      );
      return processed.length;
    } catch (e) {
      _log.error('Relay', 'Failed to sync mailbox: $e');
      return 0;
    }
  }

  /// Hand a message to the relay.
  ///
  /// Returns false when there is no live socket. Callers must not treat that
  /// as delivered - OutboxService keeps the message queued and retries.
  Future<bool> sendViaRelay(String channelKey, String payload) async {
    final conn = _conns[channelKey];
    final channel = conn?.channel;
    if (channel == null || conn?.state != RelayConnectionState.connected) {
      _log.warn('Relay', 'No active connection for $channelKey');
      return false;
    }

    try {
      channel.sink.add(_pad(payload));
      return true;
    } catch (e) {
      _log.error('Relay', 'Send failed: $e');
      return false;
    }
  }

  // -- Handshake inbox --------------------------------------------------------

  /// Deliver a contact handshake to someone we share no secret with.
  ///
  /// Writes are unauthenticated by design - a stranger has no shared secret to
  /// sign with. Reads are not: see [syncInbox].
  Future<bool> postToInbox(String identityPublicKeyHex, String payload) async {
    final inboxId = Mailbox.inboxIdFor(identityPublicKeyHex);
    for (final fallback in [false, true]) {
      try {
        final response = await http.post(
          Uri.parse('https://${_host(fallback)}/inbox/$inboxId'),
          body: _pad(payload),
        );
        if (response.statusCode == 200) return true;
      } catch (e) {
        _log.warn('Relay', 'Inbox post failed on ${_host(fallback)}: $e');
      }
    }
    return false;
  }

  /// Read and clear our own handshake inbox.
  ///
  /// Authorised with the identity key, whose public half is the inbox address,
  /// so only the owner can read what arrived.
  Future<List<String>> syncInbox(
    String myIdentityPublicKeyHex,
    String myIdentitySecretHex,
  ) async {
    final inboxId = Mailbox.inboxIdFor(myIdentityPublicKeyHex);
    final path = '/inbox/$inboxId';
    final host = _host(false);

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await http.get(
        Uri.parse('https://$host$path/sync'),
        headers: {
          'X-Spheres-Signature':
              _signWithIdentity('GET$path/sync$timestamp', myIdentitySecretHex),
          'X-Spheres-Timestamp': timestamp,
        },
      );
      if (response.statusCode != 200) return const [];

      final pending = jsonDecode(response.body) as List<dynamic>;
      if (pending.isEmpty) return const [];

      final payloads = <String>[];
      final ids = <String>[];
      for (final msg in pending) {
        final payload = _unpad(msg['data'] as String);
        if (payload != null) payloads.add(payload);
        ids.add(msg['id'] as String);
      }

      final body = jsonEncode({'ids': ids});
      final ackTs = DateTime.now().millisecondsSinceEpoch.toString();
      await http.post(
        Uri.parse('https://$host$path/ack'),
        headers: {
          'Content-Type': 'application/json',
          'X-Spheres-Signature':
              _signWithIdentity('POST$path/ack$body$ackTs', myIdentitySecretHex),
          'X-Spheres-Timestamp': ackTs,
        },
        body: body,
      );

      return payloads;
    } catch (e) {
      _log.error('Relay', 'Failed to sync inbox: $e');
      return const [];
    }
  }

  // -- Prekey bundle ----------------------------------------------------------

  /// Publish the minimum a stranger needs to start encrypting to us.
  ///
  /// Only the X25519 key and a signature over it. Display name, bio and avatar
  /// deliberately do not go here - v1 published the whole profile at an
  /// unauthenticated endpoint, so anyone holding a public key could read it.
  Future<bool> publishPrekey(
    String myIdentityPublicKeyHex,
    String myIdentitySecretHex,
    String payload,
  ) async {
    final address = Mailbox.inboxIdFor(myIdentityPublicKeyHex);
    final path = '/prekey/$address';
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await http.post(
        Uri.parse('https://${_host(false)}$path'),
        headers: {
          'X-Spheres-Signature': _signWithIdentity(
              'POST$path$payload$timestamp', myIdentitySecretHex),
          'X-Spheres-Timestamp': timestamp,
        },
        body: payload,
      );
      return response.statusCode == 200;
    } catch (e) {
      _log.error('Relay', 'Failed to publish prekey: $e');
      return false;
    }
  }

  Future<String?> fetchPrekey(String identityPublicKeyHex) async {
    final address = Mailbox.inboxIdFor(identityPublicKeyHex);
    try {
      final response =
          await http.get(Uri.parse('https://${_host(false)}/prekey/$address'));
      return response.statusCode == 200 ? response.body : null;
    } catch (e) {
      _log.error('Relay', 'Failed to fetch prekey: $e');
      return null;
    }
  }

  String _signWithIdentity(String message, String secretKeyHex) {
    final privKey = ed.PrivateKey(hex.decode(secretKeyHex));
    return hex.encode(ed.sign(privKey, utf8.encode(message)));
  }

  // -- Padding ----------------------------------------------------------------

  /// Pad to the next size bucket so the relay sees a size class, not a length.
  ///
  /// Framed as `<length>:<payload><filler>` - cheap, and unambiguous to strip.
  /// This blunts, but does not eliminate, size correlation; timing is still
  /// visible.
  String _pad(String payload) {
    final framed = '${payload.length}:$payload';
    for (final bucket in _paddingBuckets) {
      if (framed.length <= bucket) return framed.padRight(bucket, ' ');
    }
    // Larger than the biggest bucket: send as-is rather than inflating further.
    return framed;
  }

  String? _unpad(String raw) {
    final separator = raw.indexOf(':');
    if (separator <= 0) return raw;
    final length = int.tryParse(raw.substring(0, separator));
    if (length == null) return raw;

    final start = separator + 1;
    if (start + length > raw.length) {
      _log.warn('Relay', 'Discarding truncated frame');
      return null;
    }
    return raw.substring(start, start + length);
  }

  // -- Lifecycle --------------------------------------------------------------

  void disconnect(String channelKey) {
    final conn = _conns[channelKey];
    if (conn == null) return;
    conn.closedIntentionally = true;
    conn.retryTimer?.cancel();
    conn.channel?.sink.close();
    conn.channel = null;
    _conns.remove(channelKey);
    notifyListeners();
  }

  void disconnectAll() {
    for (final conn in _conns.values.toList()) {
      conn.closedIntentionally = true;
      conn.retryTimer?.cancel();
      conn.channel?.sink.close();
    }
    _conns.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _all.remove(this);
    disconnectAll();
    super.dispose();
  }
}
