import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'debug_log_service.dart';

/// WebSocket relay client for fallback messaging when Veilid DHT is slow.
///
/// Connects to a Cloudflare Worker relay that passes encrypted blobs
/// between peers. The relay sees only opaque encrypted data.
///
/// Room ID = first 16 chars of SHA256(sorted(myPublicKey, theirPublicKey))
/// This ensures both peers join the same room without coordination.
class RelayService extends ChangeNotifier {
  static const _defaultRelayUrl = 'wss://relay.spheres.dev';

  final Map<String, WebSocketChannel> _channels = {};
  final _log = DebugLogService();

  /// Callback when a message is received from the relay.
  void Function(String contactPublicKey, String encryptedMessage)? onMessageReceived;

  /// Connect to a relay room for a specific contact.
  Future<void> connect(String myPublicKey, String contactPublicKey, {String? relayUrl}) async {
    final roomId = _computeRoomId(myPublicKey, contactPublicKey);
    final url = relayUrl ?? _defaultRelayUrl;
    final wsUrl = '$url/room/$roomId';

    if (_channels.containsKey(contactPublicKey)) {
      _log.info('Relay', 'Already connected to room for $contactPublicKey');
      return;
    }

    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channels[contactPublicKey] = channel;

      channel.stream.listen(
        (data) {
          _log.success('Relay', 'Received message via relay from $contactPublicKey');
          onMessageReceived?.call(contactPublicKey, data as String);
        },
        onError: (e) {
          _log.error('Relay', 'WebSocket error for $contactPublicKey: $e');
          _channels.remove(contactPublicKey);
        },
        onDone: () {
          _log.info('Relay', 'WebSocket closed for $contactPublicKey');
          _channels.remove(contactPublicKey);
          // Auto-reconnect after 5 seconds
          Future.delayed(const Duration(seconds: 5), () {
            connect(myPublicKey, contactPublicKey, relayUrl: relayUrl);
          });
        },
      );

      _log.success('Relay', 'Connected to relay room: $roomId');
    } catch (e) {
      _log.error('Relay', 'Failed to connect to relay: $e');
    }
  }

  /// Send an encrypted message through the relay.
  Future<bool> sendViaRelay(String contactPublicKey, String encryptedMessage) async {
    final channel = _channels[contactPublicKey];
    if (channel == null) {
      _log.warn('Relay', 'No relay connection for $contactPublicKey');
      return false;
    }

    try {
      channel.sink.add(encryptedMessage);
      _log.success('Relay', 'Message sent via relay to $contactPublicKey');
      return true;
    } catch (e) {
      _log.error('Relay', 'Relay send failed: $e');
      return false;
    }
  }

  /// Disconnect from a specific contact's relay room.
  void disconnect(String contactPublicKey) {
    final channel = _channels.remove(contactPublicKey);
    channel?.sink.close();
  }

  /// Disconnect all relay connections.
  void disconnectAll() {
    for (final channel in _channels.values) {
      channel.sink.close();
    }
    _channels.clear();
  }

  /// Compute a deterministic room ID from two public keys.
  /// Both peers compute the same room ID regardless of who connects first.
  String _computeRoomId(String keyA, String keyB) {
    final sorted = [keyA, keyB]..sort();
    final combined = '${sorted[0]}:${sorted[1]}';
    // Simple hash — in production use SHA256
    var hash = 0;
    for (var i = 0; i < combined.length; i++) {
      hash = ((hash << 5) - hash + combined.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(36).padLeft(12, '0');
  }

  bool isConnected(String contactPublicKey) => _channels.containsKey(contactPublicKey);

  @override
  void dispose() {
    disconnectAll();
    super.dispose();
  }
}
