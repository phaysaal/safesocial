import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:convert/convert.dart';

import 'crypto_service.dart';
import 'debug_log_service.dart';

/// WebSocket and HTTP relay client for messaging and state sync.
class RelayService extends ChangeNotifier {
  static const _defaultRelayHost = 'relay.spheres.dev';
  static const _fallbackRelayHost = 'spheres-relay.phaysaal.workers.dev';

  final Map<String, WebSocketChannel> _channels = {};
  final _log = DebugLogService();

  // Issue #3 Fix: Message buffering
  final Map<String, List<String>> _messageBuffers = {};
  final Map<String, bool> _isSyncing = {};

  void Function(String contactPublicKey, String encryptedMessage)? onMessageReceived;

  /// Get the base URL for HTTP or WS.
  String _getBaseUrl(bool isFallback, bool isWs) {
    final host = isFallback ? _fallbackRelayHost : _defaultRelayHost;
    return isWs ? 'wss://$host' : 'https://$host';
  }

  /// Connect to a relay room for a specific contact and sync offline messages.
  /// [authPublicKey] is the raw hex Ed25519 public key used for mailbox auth.
  /// If omitted, [myPublicKey] is used (fine when it has no namespace prefix).
  Future<void> connect(String myPublicKey, String contactPublicKey, {String? mySecretKey, String? authPublicKey, bool isFallback = false}) async {
    final roomId = CryptoService.deriveRelayRoomId(myPublicKey, contactPublicKey);
    final wsUrl = '${_getBaseUrl(isFallback, true)}/room/$roomId';
    final httpUrl = '${_getBaseUrl(isFallback, false)}/room/$roomId';

    if (_channels.containsKey(contactPublicKey)) {
      return;
    }

    _isSyncing[contactPublicKey] = true;
    _messageBuffers[contactPublicKey] = [];

    _log.info('Relay', 'Connecting to $wsUrl');

    try {
      // 1. Establish real-time WebSocket connection first (start buffering)
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      
      try {
        await channel.ready;
        _log.success('Relay', 'Connected to room $roomId (Buffering messages)');
      } catch (e) {
        _log.error('Relay', 'WebSocket handshake failed: $e');
        _isSyncing.remove(contactPublicKey);
        if (!isFallback) {
          _log.warn('Relay', 'Primary relay failed, trying fallback...');
          return connect(myPublicKey, contactPublicKey, mySecretKey: mySecretKey, authPublicKey: authPublicKey, isFallback: true);
        }
        return;
      }

      _channels[contactPublicKey] = channel;

      channel.stream.listen(
        (data) {
          if (_isSyncing[contactPublicKey] == true) {
            _messageBuffers[contactPublicKey]?.add(data as String);
          } else {
            onMessageReceived?.call(contactPublicKey, data as String);
          }
        },
        onError: (e) {
          _log.error('Relay', 'WebSocket stream error: $e');
          _channels.remove(contactPublicKey);
        },
        onDone: () {
          _log.info('Relay', 'WebSocket closed, reconnecting in 5s...');
          _channels.remove(contactPublicKey);
          Future.delayed(const Duration(seconds: 5), () {
            connect(myPublicKey, contactPublicKey, mySecretKey: mySecretKey, authPublicKey: authPublicKey, isFallback: isFallback);
          });
        },
      );

      // 2. Fetch offline messages (only if we have a secret key)
      if (mySecretKey != null) {
        final pubKeyForAuth = authPublicKey ?? myPublicKey;
        await _syncOfflineMessages(httpUrl, contactPublicKey, pubKeyForAuth, mySecretKey);
      } else {
        _log.warn('Relay', 'No secret key provided; skipping offline mailbox sync for $roomId');
      }

      // 3. Flush buffer
      _isSyncing[contactPublicKey] = false;
      final buffer = _messageBuffers.remove(contactPublicKey) ?? [];
      if (buffer.isNotEmpty) {
        _log.info('Relay', 'Flushing ${buffer.length} buffered real-time messages');
        for (final msg in buffer) {
          onMessageReceived?.call(contactPublicKey, msg);
        }
      }

    } catch (e) {
      _log.error('Relay', 'Failed to connect: $e');
      _isSyncing.remove(contactPublicKey);
    }
  }

  /// Sync offline messages via HTTP GET and acknowledge receipt.
  Future<void> _syncOfflineMessages(String baseUrl, String contactPublicKey, String myPublicKey, String mySecretKey) async {
    try {
      final path = '${baseUrl.split('relay.spheres.dev').last}/sync'; // Extract path
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

  /// Send a message via relay.
  Future<bool> sendViaRelay(String contactPublicKey, String encryptedMessage) async {
    final channel = _channels[contactPublicKey];
    if (channel == null) {
      _log.warn('Relay', 'No active WS connection for $contactPublicKey');
      return false;
    }

    try {
      channel.sink.add(encryptedMessage);
      _log.success('Relay', 'Message sent via relay');
      return true;
    } catch (e) {
      _log.error('Relay', 'Send failed: $e');
      return false;
    }
  }

  void disconnect(String contactPublicKey) {
    final channel = _channels.remove(contactPublicKey);
    channel?.sink.close();
    _isSyncing.remove(contactPublicKey);
    _messageBuffers.remove(contactPublicKey);
  }

  void disconnectAll() {
    for (final channel in _channels.values) {
      channel.sink.close();
    }
    _channels.clear();
    _isSyncing.clear();
    _messageBuffers.clear();
  }

  bool isConnected(String contactPublicKey) => _channels.containsKey(contactPublicKey);

  @override
  void dispose() {
    disconnectAll();
    super.dispose();
  }
}
