import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:convert/convert.dart';

import 'crypto_service.dart';
import 'debug_log_service.dart';

/// Whether a room is usable right now.
enum RelayConnectionState { disconnected, connecting, connected }

/// Per-room connection bookkeeping.
class _Conn {
  WebSocketChannel? channel;
  RelayConnectionState state = RelayConnectionState.connecting;

  /// Set when the app closes the socket on purpose, so [onDone] does not
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
}

/// WebSocket and HTTP relay client for messaging and state sync.
class RelayService extends ChangeNotifier {
  static const _defaultRelayHost = 'relay.spheres.dev';
  static const _fallbackRelayHost = 'spheres-relay.phaysaal.workers.dev';

  static const Duration _baseRetryDelay = Duration(seconds: 2);
  static const Duration _maxRetryDelay = Duration(minutes: 2);

  final Map<String, _Conn> _conns = {};
  final _log = DebugLogService();
  final Random _jitter = Random();

  void Function(String contactPublicKey, String encryptedMessage)? onMessageReceived;

  /// Called whenever a room becomes usable, so queued work can be flushed.
  void Function(String contactPublicKey)? onConnected;

  /// Get the base URL for HTTP or WS.
  String _getBaseUrl(bool isFallback, bool isWs) {
    final host = isFallback ? _fallbackRelayHost : _defaultRelayHost;
    return isWs ? 'wss://$host' : 'https://$host';
  }

  RelayConnectionState stateFor(String contactPublicKey) =>
      _conns[contactPublicKey]?.state ?? RelayConnectionState.disconnected;

  bool isConnected(String contactPublicKey) =>
      _conns[contactPublicKey]?.state == RelayConnectionState.connected;

  void _setState(String key, RelayConnectionState state) {
    final conn = _conns[key];
    if (conn == null || conn.state == state) return;
    conn.state = state;
    notifyListeners();
  }

  /// Connect to a relay room for a specific contact and sync offline messages.
  ///
  /// [authPublicKey] is the raw hex Ed25519 public key used for mailbox auth.
  /// If omitted, [myPublicKey] is used (fine when it has no namespace prefix).
  Future<void> connect(String myPublicKey, String contactPublicKey,
      {String? mySecretKey,
      String? authPublicKey,
      bool isFallback = false}) async {
    // Claim the slot before the first await. The previous version checked for
    // an existing channel at the top but only recorded one after `await
    // channel.ready`, so two rapid calls opened two sockets and the second
    // wiped the first's buffered messages.
    final existing = _conns[contactPublicKey];
    if (existing != null &&
        (existing.state == RelayConnectionState.connected ||
            (existing.state == RelayConnectionState.connecting &&
                existing.channel != null))) {
      return;
    }
    if (existing != null && existing.state == RelayConnectionState.connecting) {
      return;
    }

    final conn = existing ?? _Conn();
    conn.closedIntentionally = false;
    conn.retryTimer?.cancel();
    conn.syncing = true;
    conn.buffer.clear();
    _conns[contactPublicKey] = conn;
    _setState(contactPublicKey, RelayConnectionState.connecting);

    final roomId = CryptoService.deriveRelayRoomId(myPublicKey, contactPublicKey);
    final wsUrl = '${_getBaseUrl(isFallback, true)}/room/$roomId';
    final httpUrl = '${_getBaseUrl(isFallback, false)}/room/$roomId';

    _log.info('Relay', 'Connecting to $wsUrl');

    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      conn.channel = channel;

      try {
        await channel.ready;
      } catch (e) {
        conn.channel = null;
        _log.error('Relay', 'WebSocket handshake failed: $e');
        if (!isFallback) {
          _log.warn('Relay', 'Primary relay failed, trying fallback...');
          _setState(contactPublicKey, RelayConnectionState.disconnected);
          _conns.remove(contactPublicKey);
          return connect(myPublicKey, contactPublicKey,
              mySecretKey: mySecretKey,
              authPublicKey: authPublicKey,
              isFallback: true);
        }
        _scheduleRetry(myPublicKey, contactPublicKey,
            mySecretKey: mySecretKey,
            authPublicKey: authPublicKey,
            isFallback: isFallback);
        return;
      }

      conn.attempt = 0;
      _log.success('Relay', 'Connected to room $roomId (buffering)');

      channel.stream.listen(
        (data) {
          if (conn.syncing) {
            conn.buffer.add(data as String);
          } else {
            onMessageReceived?.call(contactPublicKey, data as String);
          }
        },
        onError: (e) {
          _log.error('Relay', 'WebSocket stream error: $e');
        },
        onDone: () {
          conn.channel = null;
          _setState(contactPublicKey, RelayConnectionState.disconnected);
          if (conn.closedIntentionally) {
            _log.info('Relay', 'Room closed for $contactPublicKey');
            _conns.remove(contactPublicKey);
            return;
          }
          _scheduleRetry(myPublicKey, contactPublicKey,
              mySecretKey: mySecretKey,
              authPublicKey: authPublicKey,
              isFallback: isFallback);
        },
      );

      // Fetch offline messages before releasing buffered real-time frames, so
      // the caller sees them in order.
      if (mySecretKey != null) {
        final pubKeyForAuth = authPublicKey ?? myPublicKey;
        await _syncOfflineMessages(
            httpUrl, contactPublicKey, pubKeyForAuth, mySecretKey);
      } else {
        _log.warn('Relay',
            'No secret key provided; skipping offline mailbox sync for $roomId');
      }

      conn.syncing = false;
      if (conn.buffer.isNotEmpty) {
        _log.info('Relay', 'Flushing ${conn.buffer.length} buffered messages');
        for (final msg in conn.buffer) {
          onMessageReceived?.call(contactPublicKey, msg);
        }
        conn.buffer.clear();
      }

      _setState(contactPublicKey, RelayConnectionState.connected);
      onConnected?.call(contactPublicKey);
    } catch (e) {
      _log.error('Relay', 'Failed to connect: $e');
      _scheduleRetry(myPublicKey, contactPublicKey,
          mySecretKey: mySecretKey,
          authPublicKey: authPublicKey,
          isFallback: isFallback);
    }
  }

  /// Reconnect after a delay that grows with consecutive failures.
  ///
  /// Jittered so that a relay restart does not bring every client back in the
  /// same instant.
  void _scheduleRetry(String myPublicKey, String contactPublicKey,
      {String? mySecretKey, String? authPublicKey, bool isFallback = false}) {
    final conn = _conns[contactPublicKey];
    if (conn == null || conn.closedIntentionally) return;

    conn.attempt++;
    final backoffMs = _baseRetryDelay.inMilliseconds * (1 << (conn.attempt - 1));
    final cappedMs = backoffMs.clamp(
      _baseRetryDelay.inMilliseconds,
      _maxRetryDelay.inMilliseconds,
    );
    final delay = Duration(
      milliseconds: cappedMs + _jitter.nextInt(1000),
    );

    _setState(contactPublicKey, RelayConnectionState.disconnected);
    _log.info('Relay',
        'Reconnecting to $contactPublicKey in ${delay.inSeconds}s (attempt ${conn.attempt})');

    conn.retryTimer?.cancel();
    conn.retryTimer = Timer(delay, () {
      if (conn.closedIntentionally) return;
      _conns.remove(contactPublicKey);
      connect(myPublicKey, contactPublicKey,
          mySecretKey: mySecretKey,
          authPublicKey: authPublicKey,
          isFallback: isFallback);
    });
  }

  /// Sync offline messages via HTTP GET and acknowledge receipt.
  Future<void> _syncOfflineMessages(String baseUrl, String contactPublicKey, String myPublicKey, String mySecretKey) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      
      // Request format: GET /room/<id>/sync
      // Message to sign: METHOD + PATH + BODY + TIMESTAMP
      final message = 'GET${Uri.parse(baseUrl).path}/sync$timestamp';
      final signature = _signMessage(message, mySecretKey);

      final response = await http.get(
        Uri.parse('$baseUrl/sync'),
        headers: {
          'X-Spheres-PubKey': myPublicKey,
          'X-Spheres-Signature': signature,
          'X-Spheres-Timestamp': timestamp,
        },
      );

      if (response.statusCode == 200) {
        final List<dynamic> pending = jsonDecode(response.body);
        if (pending.isEmpty) return;

        _log.info('Relay', 'Found ${pending.length} offline messages');

        final List<String> processedIds = [];
        for (final msg in pending) {
          try {
            onMessageReceived?.call(contactPublicKey, msg['data'] as String);
            processedIds.add(msg['id'] as String);
          } catch (e) {
            _log.error('Relay', 'Error processing offline message: $e');
          }
        }

        if (processedIds.isNotEmpty) {
          final body = jsonEncode({'ids': processedIds});
          final ackTimestamp = DateTime.now().millisecondsSinceEpoch.toString();
          final ackMsg = 'POST${Uri.parse(baseUrl).path}/ack$body$ackTimestamp';
          final ackSig = _signMessage(ackMsg, mySecretKey);

          await http.post(
            Uri.parse('$baseUrl/ack'),
            headers: {
              'Content-Type': 'application/json',
              'X-Spheres-PubKey': myPublicKey,
              'X-Spheres-Signature': ackSig,
              'X-Spheres-Timestamp': ackTimestamp,
            },
            body: body,
          );
          _log.success('Relay', 'Cleared ${processedIds.length} offline messages');
        }
      } else if (response.statusCode == 401) {
        _log.error('Relay', 'Sync failed: Unauthorized');
      }
    } catch (e) {
      _log.error('Relay', 'Failed to sync offline messages: $e');
    }
  }

  /// Push encrypted state to the relay Key-Value store.
  Future<bool> pushState(String myPublicKey, String mySecretKey, String key, String encryptedData) async {
    try {
      final baseUrl = _getBaseUrl(false, false);
      final path = '/state/$myPublicKey/$key';
      final url = Uri.parse('$baseUrl$path');
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      
      final message = 'POST$path$encryptedData$timestamp';
      final signature = _signMessage(message, mySecretKey);

      final response = await http.post(
        url,
        headers: {
          'X-Spheres-Signature': signature,
          'X-Spheres-Timestamp': timestamp,
        },
        body: encryptedData,
      );
      return response.statusCode == 200;
    } catch (e) {
      _log.error('Relay', 'Failed to push state ($key): $e');
      return false;
    }
  }

  /// Pull encrypted state from the relay Key-Value store.
  Future<String?> pullState(String contactPublicKey, String key) async {
    try {
      final url = Uri.parse('${_getBaseUrl(false, false)}/state/$contactPublicKey/$key');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        return response.body;
      }
      return null;
    } catch (e) {
      _log.error('Relay', 'Failed to pull state ($key): $e');
      return null;
    }
  }

  /// Helper to sign a message using Ed25519.
  String _signMessage(String message, String secretKeyHex) {
    final privKey = ed.PrivateKey(hex.decode(secretKeyHex));
    final sig = ed.sign(privKey, utf8.encode(message));
    return hex.encode(sig);
  }

  /// Hand a message to the relay.
  ///
  /// Returns false when there is no live socket. Callers must not treat that
  /// as delivered — [OutboxService] keeps the message queued and retries.
  Future<bool> sendViaRelay(String contactPublicKey, String encryptedMessage) async {
    final conn = _conns[contactPublicKey];
    final channel = conn?.channel;
    if (channel == null || conn?.state != RelayConnectionState.connected) {
      _log.warn('Relay', 'No active WS connection for $contactPublicKey');
      return false;
    }

    try {
      channel.sink.add(encryptedMessage);
      return true;
    } catch (e) {
      _log.error('Relay', 'Send failed: $e');
      return false;
    }
  }

  void disconnect(String contactPublicKey) {
    final conn = _conns[contactPublicKey];
    if (conn == null) return;
    conn.closedIntentionally = true;
    conn.retryTimer?.cancel();
    conn.channel?.sink.close();
    conn.channel = null;
    _conns.remove(contactPublicKey);
    notifyListeners();
  }

  void disconnectAll() {
    for (final entry in _conns.entries.toList()) {
      entry.value.closedIntentionally = true;
      entry.value.retryTimer?.cancel();
      entry.value.channel?.sink.close();
    }
    _conns.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    disconnectAll();
    super.dispose();
  }
}
