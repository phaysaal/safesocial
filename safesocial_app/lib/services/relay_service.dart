import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'crypto_service.dart';
import 'debug_log_service.dart';

/// WebSocket relay client for messaging.
class RelayService extends ChangeNotifier {
  static const _defaultRelayUrl = 'wss://relay.spheres.dev';
  static const _fallbackRelayUrl = 'wss://spheres-relay.phaysaal.workers.dev';

  final Map<String, WebSocketChannel> _channels = {};
  final _log = DebugLogService();

  void Function(String contactPublicKey, String encryptedMessage)? onMessageReceived;

  /// Connect to a relay room for a specific contact.
  Future<void> connect(String myPublicKey, String contactPublicKey, {String? relayUrl, bool isFallback = false}) async {
    final roomId = CryptoService.deriveRelayRoomId(myPublicKey, contactPublicKey);
    final url = relayUrl ?? (isFallback ? _fallbackRelayUrl : _defaultRelayUrl);
    final wsUrl = '$url/room/$roomId';

    if (_channels.containsKey(contactPublicKey)) {
      return;
    }

    _log.info('Relay', 'Connecting to $wsUrl');

    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Wait for the connection to be ready
      try {
        await channel.ready;
        _log.success('Relay', 'Connected to room $roomId');
      } catch (e) {
        _log.error('Relay', 'WebSocket handshake failed: $e');
        
        // Try fallback if not already using it
        if (!isFallback && relayUrl == null) {
          _log.warn('Relay', 'Primary relay failed, trying fallback...');
          return connect(myPublicKey, contactPublicKey, isFallback: true);
        }
        return;
      }

      _channels[contactPublicKey] = channel;

      channel.stream.listen(
        (data) {
          _log.success('Relay', 'Received message via relay');
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
            connect(myPublicKey, contactPublicKey, relayUrl: relayUrl);
          });
        },
      );
    } catch (e) {
      _log.error('Relay', 'Failed to connect: $e');
    }
  }

  /// Send a message via relay.
  Future<bool> sendViaRelay(String contactPublicKey, String encryptedMessage) async {
    final channel = _channels[contactPublicKey];
    if (channel == null) {
      _log.warn('Relay', 'No connection for ${contactPublicKey.length > 12 ? '${contactPublicKey.substring(0, 8)}...' : contactPublicKey}');
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
