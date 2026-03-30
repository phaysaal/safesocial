import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'crypto_service.dart';
import 'debug_log_service.dart';

/// WebSocket and HTTP relay client for messaging and state sync.
class RelayService extends ChangeNotifier {
  static const _defaultRelayHost = 'relay.spheres.dev';
  static const _fallbackRelayHost = 'spheres-relay.phaysaal.workers.dev';

  final Map<String, WebSocketChannel> _channels = {};
  final _log = DebugLogService();

  void Function(String contactPublicKey, String encryptedMessage)? onMessageReceived;

  /// Get the base URL for HTTP or WS.
  String _getBaseUrl(bool isFallback, bool isWs) {
    final host = isFallback ? _fallbackRelayHost : _defaultRelayHost;
    return isWs ? 'wss://$host' : 'https://$host';
  }

  /// Connect to a relay room for a specific contact and sync offline messages.
  Future<void> connect(String myPublicKey, String contactPublicKey, {bool isFallback = false}) async {
    final roomId = CryptoService.deriveRelayRoomId(myPublicKey, contactPublicKey);
    final wsUrl = '${_getBaseUrl(isFallback, true)}/room/$roomId';
    final httpUrl = '${_getBaseUrl(isFallback, false)}/room/$roomId';

    if (_channels.containsKey(contactPublicKey)) {
      return;
    }

    _log.info('Relay', 'Connecting to $wsUrl');

    try {
      // 1. Fetch offline messages first
      await _syncOfflineMessages(httpUrl, contactPublicKey);

      // 2. Establish real-time WebSocket connection
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      try {
        await channel.ready;
        _log.success('Relay', 'Connected to room $roomId');
      } catch (e) {
        _log.error('Relay', 'WebSocket handshake failed: $e');
        if (!isFallback) {
          _log.warn('Relay', 'Primary relay failed, trying fallback...');
          return connect(myPublicKey, contactPublicKey, isFallback: true);
        }
        return;
      }

      _channels[contactPublicKey] = channel;

      channel.stream.listen(
        (data) {
          _log.success('Relay', 'Received real-time message');
          onMessageReceived?.call(contactPublicKey, data as String);
        },
        onError: (e) {
          _log.error('Relay', 'WebSocket stream error: $e');
          _channels.remove(contactPublicKey);
        },
        onDone: () {
          _log.info('Relay', 'WebSocket closed, reconnecting in 5s...');
          _channels.remove(contactPublicKey);
          Future.delayed(const Duration(seconds: 5), () {
            connect(myPublicKey, contactPublicKey, isFallback: isFallback);
          });
        },
      );
    } catch (e) {
      _log.error('Relay', 'Failed to connect: $e');
    }
  }

  /// Sync offline messages via HTTP GET and acknowledge receipt.
  Future<void> _syncOfflineMessages(String baseUrl, String contactPublicKey) async {
    try {
      final syncUrl = Uri.parse('$baseUrl/sync');
      final response = await http.get(syncUrl);

      if (response.statusCode == 200) {
        final List<dynamic> pending = jsonDecode(response.body);
        if (pending.isEmpty) return;

        _log.info('Relay', 'Found ${pending.length} offline messages. Processing...');

        final List<String> processedIds = [];

        for (final msg in pending) {
          final data = msg['data'] as String;
          final id = msg['id'] as String;
          
          try {
            onMessageReceived?.call(contactPublicKey, data);
            processedIds.add(id);
          } catch (e) {
            _log.error('Relay', 'Error processing offline message: $e');
          }
        }

        // Acknowledge processed messages to clear them from the server mailbox
        if (processedIds.isNotEmpty) {
          await http.post(
            Uri.parse('$baseUrl/ack'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'ids': processedIds}),
          );
          _log.success('Relay', 'Cleared ${processedIds.length} offline messages from mailbox');
        }
      }
    } catch (e) {
      _log.error('Relay', 'Failed to sync offline messages: $e');
    }
  }

  /// Push encrypted state to the relay Key-Value store.
  Future<bool> pushState(String myPublicKey, String key, String encryptedData) async {
    try {
      final url = Uri.parse('${_getBaseUrl(false, false)}/state/$myPublicKey/$key');
      final response = await http.post(url, body: encryptedData);
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
      return null; // 404 Not Found or other error
    } catch (e) {
      _log.error('Relay', 'Failed to pull state ($key): $e');
      return null;
    }
  }

  /// Send a message via relay.
  Future<bool> sendViaRelay(String contactPublicKey, String encryptedMessage) async {
    final channel = _channels[contactPublicKey];
    if (channel == null) {
      _log.warn('Relay', 'No active WS connection for $contactPublicKey. Message will be queued locally.');
      // FUTURE: Implement local outbox if connection drops entirely.
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
  }

  void disconnectAll() {
    for (final channel in _channels.values) {
      channel.sink.close();
    }
    _channels.clear();
  }

  bool isConnected(String contactPublicKey) => _channels.containsKey(contactPublicKey);

  @override
  void dispose() {
    disconnectAll();
    super.dispose();
  }
}
