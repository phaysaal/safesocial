import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:collection';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/mailbox.dart';
import '../crypto/session_manager.dart';
import 'debug_log_service.dart';
import 'wake_service.dart';
import 'relay_config.dart';

/// Whether a channel is usable right now.
enum RelayConnectionState { disconnected, connecting, connected }

/// The socket the hub talks over. Abstracted so tests can drive the protocol
/// without a network, and so the transport can change without touching the
/// subscription logic.
abstract class RelaySocket {
  Future<void> get ready;
  Stream<dynamic> get stream;
  void send(String frame);
  Future<void> close();
}

class _WebSocketRelaySocket implements RelaySocket {
  final WebSocketChannel _channel;
  _WebSocketRelaySocket(Uri uri) : _channel = WebSocketChannel.connect(uri);

  @override
  Future<void> get ready => _channel.ready;
  @override
  Stream<dynamic> get stream => _channel.stream;
  @override
  void send(String frame) => _channel.sink.add(frame);
  @override
  Future<void> close() => _channel.sink.close();
}

/// Someone who wants to hear about one mailbox, under their own local name.
///
/// Public only so [RelayHub] can name it in signatures; services never
/// construct one.
class RelayListener {
  final RelayService owner;
  final String channelKey;
  RelayListener(this.owner, this.channelKey);

  @override
  bool operator ==(Object other) =>
      other is RelayListener && other.owner == owner && other.channelKey == channelKey;
  @override
  int get hashCode => Object.hash(owner, channelKey);
}

/// One mailbox the hub is (or wants to be) subscribed to.
/// Hosts to try for a plain HTTP call, in order: the configured relay, then
/// the workers.dev name when the configured one is the default domain. A
/// custom relay has no fallback we could know about.
List<String> relayHttpHosts() =>
    RelayConfig.primaryHost == RelayConfig.defaultHost
        ? [RelayConfig.primaryHost, RelayConfig.fallbackHost]
        : [RelayConfig.primaryHost];

/// Run [call] against each host until one answers at all.
///
/// A transport failure (name lookup, refused connection, timeout) moves to
/// the next host; any HTTP status is an answer and is returned as is. The
/// hub socket has failed over like this since the first custom-domain
/// outage; the HTTP calls kept retrying the dead name, which on a phone
/// whose Wi-Fi drops name resolution for a minute at a time meant handshakes
/// and prekeys waited that minute too. Signatures cover method, path, body
/// and time, never the host, so a retry elsewhere verifies the same.
Future<http.Response> relayHttp(
  Future<http.Response> Function(String host) call, {
  @visibleForTesting List<String>? hosts,
}) async {
  final candidates = hosts ?? relayHttpHosts();
  Object? last;
  for (var i = 0; i < candidates.length; i++) {
    try {
      return await call(candidates[i]);
    } on SocketException catch (e) {
      last = e;
    } on http.ClientException catch (e) {
      last = e;
    } on TimeoutException catch (e) {
      last = e;
    }
    if (i + 1 < candidates.length) {
      DebugLogService().warn('Relay',
          'No answer from ${candidates[i]}; trying ${candidates[i + 1]}');
    }
  }
  throw last ?? StateError('No relay host configured');
}

class RelaySubscription {
  final Mailbox mailbox;
  final Set<RelayListener> listeners = {};

  /// X25519 key of the peer device this mailbox is shared with, when the
  /// channel has several devices behind it. Null for single-device channels.
  final String? deviceKey;

  /// The relay has confirmed the subscription.
  bool subscribed = false;

  /// Offline mail is being drained; live frames wait so ordering is kept.
  bool syncing = false;
  final List<String> buffer = [];

  /// When this mailbox last produced any evidence of being alive.
  DateTime lastActivity = DateTime.now();

  RelaySubscription(this.mailbox, {this.deviceKey});
}

/// One connection to the relay for the whole app.
///
/// Before this, every service held its own `RelayService` and every mailbox
/// its own WebSocket: a phone with thirty contacts ran ninety sockets (chat,
/// feed and call channels each), each with a reconnect loop and a watchdog.
/// On mobile that is ninety things that can silently die when the network
/// changes. Now there is one socket, to a hub object on the relay named by a
/// random id minted at launch, and each mailbox is subscribed over it by
/// signing with that mailbox's key — the same proof the direct upgrade used,
/// so the relay learns nothing it could not see before.
///
/// Services keep the `RelayService` API they always had; it is now a thin
/// facade that registers listeners here.
class RelayHub {
  RelayHub._();
  static RelayHub instance = RelayHub._();

  /// Replaceable for tests.
  RelaySocket Function(Uri uri) connector = _WebSocketRelaySocket.new;

  static const Duration _baseRetryDelay = Duration(seconds: 2);
  static const Duration _maxRetryDelay = Duration(minutes: 2);

  /// A ping goes out after this much silence; a socket that answers nothing
  /// for twice as long is replaced.
  static const Duration pingAfter = Duration(seconds: 45);

  /// Payloads are padded up to the next bucket, so the operator learns a size
  /// class rather than an exact length.
  static const List<int> _paddingBuckets = [512, 2048, 8192, 32768, 131072];

  final _log = DebugLogService();
  final Random _random = Random.secure();

  /// This install's name on the relay, part of the socket URL. Stable across
  /// restarts on purpose: a mailbox holds a slot per hub, so a fresh id on
  /// every process (and every headless wake) filled the Fai–Al mailboxes
  /// with dead subscribers inside a day and the relay began refusing live
  /// ones. The relay could already link one install's sessions by the set of
  /// mailboxes it opens, so a stable id tells it nothing new.
  late String _hubId = _mintHubId();
  static const _hubIdKey = 'spheres_hub_id';

  /// Use the id stored for this install, or store the one just minted.
  /// Called once at boot, before any socket is opened.
  Future<void> adoptStoredId() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_hubIdKey);
    if (stored != null && stored.isNotEmpty) {
      _hubId = stored;
    } else {
      await prefs.setString(_hubIdKey, _hubId);
    }
  }

  @visibleForTesting
  String get hubId => _hubId;

  final Map<String, RelaySubscription> _subs = {};

  RelaySocket? _socket;
  bool _connected = false;
  bool _connecting = false;

  /// Set by [rest]: the socket was let go on purpose and must not come back
  /// on a timer. The next connect attempt, however it is triggered, clears it.
  bool _resting = false;
  bool _usingFallback = false;
  int _attempt = 0;
  Timer? _retryTimer;
  Timer? _pingTimer;
  DateTime _lastFrame = DateTime.now();
  int _nextSendId = 1;

  /// Publishes waiting for the relay's `sent` frame, by send id.
  final Map<int, _PendingSend> _pendingSends = {};

  /// Digests of payloads this client has already delivered to a listener or
  /// published itself.
  ///
  /// The relay keeps every message queued until an HTTP sync acknowledges
  /// it, and a mailbox is shared by both parties, so a drain hands back
  /// what the socket already delivered and, to the sender, its own
  /// messages. Both were being passed to listeners again: peers' messages
  /// were discarded as duplicates, but our own could not be opened and
  /// looked like a broken session. Now a drain acknowledges them and
  /// delivers nothing twice, and only genuinely new mail counts as
  /// evidence that a quiet socket is dead.
  final Set<String> _seen = {};
  final Queue<String> _seenOrder = Queue<String>();
  static const int _seenLimit = 4000;

  /// How long a publish may wait for the relay to confirm it took the
  /// message. A socket that is half dead accepts writes and answers nothing;
  /// without this, the outbox marked such messages sent and they were lost.
  static Duration sendAckTimeout = const Duration(seconds: 10);

  static String _digest(String payload) =>
      sha256.convert(utf8.encode(payload)).toString();

  /// Remember [payload]; true if it was new.
  bool _remember(String payload) {
    final digest = _digest(payload);
    if (!_seen.add(digest)) return false;
    _seenOrder.add(digest);
    while (_seenOrder.length > _seenLimit) {
      _seen.remove(_seenOrder.removeFirst());
    }
    return true;
  }

  String _mintHubId() {
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  bool get isConnected => _connected;

  @visibleForTesting
  int get subscriptionCount => _subs.length;

  /// Whether a reconnect is waiting on the backoff timer. Tests only.
  @visibleForTesting
  bool get debugRetryPending => _retryTimer != null;

  /// Let the socket go but keep every subscription, so the next [verifyIdle]
  /// brings it straight back. The headless wake calls this when its window
  /// closes: Android cuts the process's network soon after, and a socket
  /// retrying from a frozen process is wasted battery and log noise. Pending
  /// publishes are reported as not sent, the same as any other closed socket.
  bool _paused = false;

  /// Paused: the socket rests and nothing reconnects until [resume]. The
  /// subscriptions and keys stay; the user is simply away.
  bool get paused => _paused;

  void pause() {
    _paused = true;
    rest();
  }

  Future<void> resume() async {
    _paused = false;
    await verifyIdle();
  }

  void rest() {
    _resting = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    final socket = _socket;
    if (socket == null) return;
    _onClosed();
    unawaited(socket.close().catchError((_) {}));
  }

  /// Every mailbox currently subscribed, for whoever registers wake targets.
  Iterable<Mailbox> get mailboxes => _subs.values.map((s) => s.mailbox);

  /// A mailbox was added or dropped. WakeService listens so the relay knows
  /// where to knock for each one.
  void Function(Mailbox mailbox)? onSubscribed;
  void Function(Mailbox mailbox)? onForgotten;

  String _host() => _usingFallback
      ? (RelayConfig.primaryHost == RelayConfig.defaultHost
          ? RelayConfig.fallbackHost
          : RelayConfig.primaryHost)
      : RelayConfig.primaryHost;

  // -- Listeners --------------------------------------------------------------

  /// Hear about [mailbox] as [listener]. Opens the hub if needed.
  ///
  /// [deviceKey] names the peer device behind this mailbox, so a later
  /// [publish] for that device finds the right one.
  Future<void> listen(RelayListener listener, Mailbox mailbox,
      {String? deviceKey}) async {
    var sub = _subs[mailbox.id];
    if (sub == null) {
      sub = RelaySubscription(mailbox, deviceKey: deviceKey);
      _subs[mailbox.id] = sub;
      sub.listeners.add(listener);
      onSubscribed?.call(mailbox);
      listener.owner._setState(listener.channelKey, RelayConnectionState.connecting);
      if (_connected) {
        _sendSubscribe(sub);
      } else if (!_resting) {
        // Resting (off screen, or a headless window closed): the mailbox is
        // remembered and subscribed when the socket next returns. Opening
        // it here undid the rest on the Samsung, where services were still
        // subscribing mailboxes as the app went behind the lock screen.
        _ensureConnected();
      }
      return;
    }

    sub.listeners.add(listener);
    if (sub.subscribed && !sub.syncing) {
      listener.owner._setState(listener.channelKey, RelayConnectionState.connected);
      listener.owner.onConnected?.call(listener.channelKey);
    } else {
      listener.owner._setState(listener.channelKey, RelayConnectionState.connecting);
    }
  }

  /// Stop hearing about the mailbox behind [listener].
  void forget(RelayListener listener) {
    for (final entry in _subs.entries.toList()) {
      final sub = entry.value;
      if (!sub.listeners.remove(listener)) continue;
      if (sub.listeners.isEmpty) {
        _subs.remove(entry.key);
        if (_connected) {
          _send({'t': 'unsub', 'a': entry.key});
        }
        onForgotten?.call(sub.mailbox);
      }
    }
    if (_subs.isEmpty) _closeIdle();
  }

  /// Which relay the peer behind a channel key listens on, or null for ours.
  /// Set by the app from the contact list; federation lives here.
  String? Function(String channelKey)? peerHostResolver;

  /// Stand-in for the cross-relay HTTP post, for tests.
  @visibleForTesting
  Future<bool> Function(String host, Mailbox mailbox, String payload)?
      remotePostOverride;

  /// Hand a payload to the relay for the mailbox behind [listener].
  ///
  /// If the peer listens on another relay, the payload goes there with a
  /// signed HTTP post; otherwise over our hub socket. Returns false when it
  /// could not be handed over. Callers must not treat that as delivered -
  /// OutboxService keeps the message queued and retries.
  Future<bool> publish(RelayListener listener, String payload,
      {String? deviceKey}) async {
    final sub = _subFor(listener, deviceKey: deviceKey);
    if (sub == null) {
      _log.warn('Relay',
          'No subscription for ${listener.channelKey}${deviceKey == null ? '' : ' (device)'}');
      return false;
    }

    final peerHost = peerHostResolver?.call(listener.channelKey);
    if (peerHost != null && peerHost != RelayConfig.primaryHost) {
      return _postRemote(peerHost, sub.mailbox, _pad(payload));
    }

    if (!sub.subscribed || !_connected) {
      _log.warn('Relay', 'No active connection for ${listener.channelKey}');
      return false;
    }
    final id = _nextSendId++;
    final pending = _PendingSend(sub.mailbox.id);
    _pendingSends[id] = pending;
    // A shared mailbox will hand this back to us on the next drain.
    _remember(payload);
    final written = _send({
      't': 'pub',
      'a': sub.mailbox.id,
      'd': _pad(payload),
      'id': id,
    });
    if (!written) {
      _pendingSends.remove(id);
      return false;
    }
    // Only the relay's own word counts as sent. A write that is never
    // answered is treated as not sent, so the outbox keeps it and retries.
    return pending.completer.future.timeout(sendAckTimeout, onTimeout: () {
      if (_pendingSends.remove(id) != null) {
        _log.warn('Relay',
            'No acknowledgement for a publish to ${listener.channelKey} within '
            '${sendAckTimeout.inSeconds}s; keeping it to retry');
      }
      return false;
    });
  }

  /// Answer every publish still waiting on [address] (or all of them) with
  /// [ok]. Called on error frames and whenever the socket goes away.
  void _settlePendingSends({String? address, required bool ok}) {
    final ids = _pendingSends.entries
        .where((e) => address == null || e.value.address == address)
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      final pending = _pendingSends.remove(id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.complete(ok);
      }
    }
  }

  /// Drop a payload into the mailbox on another relay, signed by the mailbox
  /// key. The other relay learns exactly what ours would: an address and
  /// ciphertext.
  Future<bool> _postRemote(String host, Mailbox mailbox, String padded) async {
    final override = remotePostOverride;
    if (override != null) return override(host, mailbox, padded);
    final path = '/mbx/${mailbox.id}/post';
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await http.post(
        Uri.parse('https://$host$path'),
        headers: {
          'X-Spheres-Signature': mailbox.sign('POST', path, padded, timestamp),
          'X-Spheres-Timestamp': timestamp,
        },
        body: padded,
      );
      if (response.statusCode == 200) return true;
      _log.warn('Relay', 'Relay $host refused the post: ${response.statusCode}');
      return false;
    } catch (e) {
      _log.warn('Relay', 'Could not reach relay $host: $e');
      return false;
    }
  }

  /// The subscription for a listener — and, when [deviceKey] is given, for
  /// that device in particular. Without one, the first device found.
  RelaySubscription? _subFor(RelayListener listener, {String? deviceKey}) {
    RelaySubscription? any;
    for (final sub in _subs.values) {
      if (!sub.listeners.contains(listener)) continue;
      if (deviceKey == null) return sub;
      if (sub.deviceKey == deviceKey) return sub;
      any ??= sub.deviceKey == null ? sub : null;
    }
    return any;
  }

  /// Connected if any mailbox behind the channel is.
  RelayConnectionState stateOf(RelayListener listener) {
    var state = RelayConnectionState.disconnected;
    for (final sub in _subs.values) {
      if (!sub.listeners.contains(listener)) continue;
      if (_connected && sub.subscribed && !sub.syncing) {
        return RelayConnectionState.connected;
      }
      state = RelayConnectionState.connecting;
    }
    return state;
  }

  // -- Connection -------------------------------------------------------------

  void _ensureConnected() {
    if (_connected || _connecting) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_connecting || _connected || _paused) return;
    _connecting = true;
    _resting = false;

    final host = _host();
    final uri = Uri.parse('wss://$host/hub/$_hubId');
    RelaySocket socket;
    try {
      socket = connector(uri);
      await socket.ready;
    } catch (e) {
      _connecting = false;
      _log.error('Relay', 'Hub handshake failed on $host: $e');
      if (!_usingFallback && RelayConfig.primaryHost == RelayConfig.defaultHost) {
        // Fail over once. The retry after that goes back to the primary, so a
        // blip does not strand the client on the fallback for good.
        _usingFallback = true;
        return _connect();
      }
      _usingFallback = false;
      _scheduleRetry();
      return;
    }

    _socket = socket;
    _connected = true;
    _connecting = false;
    _attempt = 0;
    _lastFrame = DateTime.now();
    _log.info('Relay', 'Hub connected via $host');

    socket.stream.listen(
      _onFrame,
      onError: (e) => _log.error('Relay', 'Hub stream error: $e'),
      onDone: _onClosed,
    );

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingAfter, (_) => _heartbeat());

    for (final sub in _subs.values) {
      _sendSubscribe(sub);
    }
  }

  void _onClosed() {
    final wasConnected = _connected;
    _connected = false;
    _socket = null;
    _settlePendingSends(ok: false);
    _pingTimer?.cancel();
    _pingTimer = null;

    for (final sub in _subs.values) {
      sub.subscribed = false;
      sub.syncing = false;
      sub.buffer.clear();
      for (final l in sub.listeners) {
        l.owner._setState(l.channelKey, RelayConnectionState.connecting);
      }
    }

    if (_subs.isEmpty) return;
    if (wasConnected) _log.warn('Relay', 'Hub socket closed');
    _scheduleRetry();
  }

  /// Reconnect after a delay that grows with consecutive failures.
  ///
  /// Jittered so a relay restart does not bring every client back at once.
  void _scheduleRetry() {
    if (_subs.isEmpty || _resting || _paused) return;
    _attempt++;
    final backoffMs = _baseRetryDelay.inMilliseconds * (1 << min(_attempt - 1, 10));
    final cappedMs = backoffMs.clamp(
      _baseRetryDelay.inMilliseconds,
      _maxRetryDelay.inMilliseconds,
    );
    final delay = Duration(milliseconds: cappedMs + _random.nextInt(1000));
    _log.info('Relay', 'Reconnecting hub in ${delay.inSeconds}s (attempt $_attempt)');

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      // Always come back to the primary; the fallback is for one attempt.
      _usingFallback = false;
      unawaited(_connect());
    });
  }

  /// Nobody is listening to anything: let the socket go.
  void _closeIdle() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    final socket = _socket;
    _socket = null;
    _connected = false;
    _connecting = false;
    if (socket != null) unawaited(socket.close().catchError((_) {}));
  }

  /// Replace a socket that has stopped answering.
  Future<void> _replaceSocket(String why) async {
    _log.warn('Relay', 'Replacing hub socket: $why');
    final socket = _socket;
    _socket = null;
    _connected = false;
    _settlePendingSends(ok: false);
    _pingTimer?.cancel();
    _pingTimer = null;
    for (final sub in _subs.values) {
      sub.subscribed = false;
      sub.syncing = false;
      sub.buffer.clear();
      for (final l in sub.listeners) {
        l.owner._setState(l.channelKey, RelayConnectionState.connecting);
      }
    }
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
    }
    _attempt = 0;
    unawaited(_connect());
  }

  void _heartbeat() {
    if (!_connected) return;
    final quiet = DateTime.now().difference(_lastFrame);
    if (quiet > pingAfter * 2) {
      unawaited(_replaceSocket('no frames for ${quiet.inSeconds}s'));
      return;
    }
    if (quiet >= pingAfter) _send({'t': 'ping'});
  }

  bool _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null || !_connected) return false;
    try {
      socket.send(jsonEncode(frame));
      return true;
    } catch (e) {
      _log.error('Relay', 'Send failed: $e');
      return false;
    }
  }

  void _sendSubscribe(RelaySubscription sub) {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final address = sub.mailbox.id;
    _send({
      't': 'sub',
      'a': address,
      'ts': ts,
      'sig': sub.mailbox.signRaw('SUB$address$ts'),
    });
  }

  // -- Frames -----------------------------------------------------------------

  void _onFrame(dynamic data) {
    _lastFrame = DateTime.now();
    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      _log.warn('Relay', 'Discarding malformed hub frame');
      return;
    }

    final type = frame['t'];
    if (type == 'pong') return;

    final address = frame['a'];
    if (address is! String) return;
    final sub = _subs[address];
    if (sub == null) return;
    sub.lastActivity = DateTime.now();

    switch (type) {
      case 'ok':
        if (!sub.subscribed) {
          sub.subscribed = true;
          unawaited(_drainThenRelease(sub));
        }
      case 'msg':
        final payload = _unpad(frame['d'] as String? ?? '');
        if (payload == null) return;
        if (!_remember(payload)) return; // already delivered or our own
        if (sub.syncing || !sub.subscribed) {
          sub.buffer.add(payload);
        } else {
          _deliver(sub, payload);
        }
      case 'err':
        final why = frame['e'];
        // Whatever the reason, nothing published to this address just now
        // was taken.
        _settlePendingSends(address: address, ok: false);
        if (why == 'unsubscribed') {
          // The mailbox forgot us, or gave our slot to a newer hub; prove
          // the key again.
          sub.subscribed = false;
          _sendSubscribe(sub);
        } else if (why == 'unauthorized') {
          _log.error('Relay', 'Mailbox refused our key for ${_label(sub)}');
        } else if (why == 'full') {
          _log.warn('Relay', 'Mailbox full for ${_label(sub)}; message not stored');
        } else {
          _log.warn('Relay', 'Hub error $why for ${_label(sub)}');
        }
      case 'sent':
        final id = frame['id'];
        final pending = id is int ? _pendingSends.remove(id) : null;
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(true);
        }
      default:
        _log.warn('Relay', 'Unknown hub frame type $type');
    }
  }

  String _label(RelaySubscription sub) =>
      sub.listeners.isEmpty ? sub.mailbox.id.substring(0, 8) : sub.listeners.first.channelKey;

  /// Drain the offline mailbox before releasing buffered live frames, so the
  /// listener sees them in order.
  Future<void> _drainThenRelease(RelaySubscription sub) async {
    sub.syncing = true;
    await syncMailbox(sub);
    sub.syncing = false;
    if (!sub.subscribed) return;

    for (final payload in sub.buffer) {
      _deliver(sub, payload);
    }
    sub.buffer.clear();

    for (final l in sub.listeners.toList()) {
      l.owner._setState(l.channelKey, RelayConnectionState.connected);
      l.owner.onConnected?.call(l.channelKey);
    }
  }

  void _deliver(RelaySubscription sub, String payload) {
    for (final l in sub.listeners.toList()) {
      try {
        l.owner.onMessageReceived?.call(l.channelKey, payload);
      } catch (e) {
        _log.error('Relay', 'Listener threw on ${l.channelKey}: $e');
      }
    }
  }

  /// Fetch anything waiting in the mailbox over HTTP, acknowledging all of
  /// it and returning how many were new to this client.
  ///
  /// The count is what makes a liveness check meaningful: new messages found
  /// here on a supposedly connected socket are messages that socket failed
  /// to deliver. Copies of what it did deliver, and our own messages coming
  /// back from a shared mailbox, are acknowledged and not counted.
  Future<int> syncMailbox(RelaySubscription sub) async {
    final override = syncOverride;
    if (override != null) {
      return override(sub.mailbox, (payload) => _acceptFromDrain(sub, payload));
    }
    final path = '/mbx/${sub.mailbox.id}';
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final signature = sub.mailbox.sign('GET', '$path/sync', '', timestamp);

      final response = await relayHttp((host) => http.get(
            Uri.parse('https://$host$path/sync'),
            headers: {
              'X-Spheres-Signature': signature,
              'X-Spheres-Timestamp': timestamp,
            },
          ));

      if (response.statusCode == 401) {
        _log.error('Relay', 'Mailbox sync rejected: unauthorized');
        return 0;
      }
      if (response.statusCode != 200) return 0;

      final pending = jsonDecode(response.body) as List<dynamic>;
      if (pending.isEmpty) return 0;

      final processed = <String>[];
      var fresh = 0;
      for (final msg in pending) {
        try {
          final payload = _unpad(msg['data'] as String);
          if (payload != null && _acceptFromDrain(sub, payload)) fresh++;
          processed.add(msg['id'] as String);
        } catch (e) {
          _log.error('Relay', 'Could not process queued message: $e');
        }
      }

      if (processed.isEmpty) return 0;

      final body = jsonEncode({'ids': processed});
      final ackTs = DateTime.now().millisecondsSinceEpoch.toString();
      await relayHttp((host) => http.post(
            Uri.parse('https://$host$path/ack'),
            headers: {
              'Content-Type': 'application/json',
              'X-Spheres-Signature': sub.mailbox.sign('POST', '$path/ack', body, ackTs),
              'X-Spheres-Timestamp': ackTs,
            },
            body: body,
          ));
      return fresh;
    } catch (e) {
      _log.error('Relay', 'Failed to sync mailbox: $e');
      return 0;
    }
  }

  /// Deliver a drained payload unless it was already delivered live or is
  /// one of our own. Returns whether it was new.
  bool _acceptFromDrain(RelaySubscription sub, String payload) {
    if (!_remember(payload)) return false;
    _deliver(sub, payload);
    return true;
  }

  // -- Liveness ---------------------------------------------------------------

  /// How long a mailbox may go quiet before we check it is really there.
  static const Duration idleBefore = Duration(minutes: 2);

  /// Prove quiet subscriptions are still delivering, and repair the socket if
  /// not.
  ///
  /// The check is evidence-based rather than a guess: fetch the mailbox over
  /// HTTP, which does not depend on the socket at all. If anything was waiting
  /// there, the socket demonstrably failed to deliver it, so it is replaced.
  Future<void> verifyIdle() async {
    if (_paused) return;
    if (!_connected) {
      // Resumed with no socket and things to listen to: do not wait for the
      // backoff timer.
      if (_subs.isNotEmpty && !_connecting) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _attempt = 0;
        unawaited(_connect());
      }
      return;
    }

    final now = DateTime.now();
    for (final sub in _subs.values.toList()) {
      if (!sub.subscribed || sub.syncing) continue;
      if (now.difference(sub.lastActivity) < idleBefore) continue;

      final recovered = await syncMailbox(sub);
      sub.lastActivity = DateTime.now();
      if (recovered > 0) {
        await _replaceSocket(
            'a quiet subscription had $recovered message(s) waiting');
        return;
      }
    }
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

  // -- Testing ----------------------------------------------------------------

  /// Stand-in for the HTTP mailbox drain, so protocol tests need no network.
  @visibleForTesting
  Future<int> Function(Mailbox mailbox, bool Function(String payload) deliver)?
      syncOverride;

  /// Feed a frame as if the relay had sent it.
  @visibleForTesting
  void debugReceive(String frame) => _onFrame(frame);

  /// The subscription for a mailbox address, for tests that drain it.
  @visibleForTesting
  RelaySubscription? debugSubscription(String address) => _subs[address];

  /// Tear everything down. Tests only.
  @visibleForTesting
  void debugReset() {
    _settlePendingSends(ok: false);
    _seen.clear();
    _seenOrder.clear();
    _closeIdle();
    _subs.clear();
    _hubId = _mintHubId();
    _attempt = 0;
    _usingFallback = false;
    syncOverride = null;
    onSubscribed = null;
    onForgotten = null;
    peerHostResolver = null;
    remotePostOverride = null;
  }
}

/// Client for the relay, as seen by one service.
///
/// Each service keeps its own instance so it has its own callbacks; all of
/// them share one socket through [RelayHub]. Channel keys are local handles
/// (usually a contact's public key) and never reach the relay.
class RelayService extends ChangeNotifier {
  final _log = DebugLogService();

  /// Every live facade, so one check can cover them all.
  static final Set<RelayService> _all = {};

  /// How long a connection may go quiet before we check it is really there.
  static const Duration idleBefore = RelayHub.idleBefore;

  /// Ask the shared hub to check its quiet subscriptions.
  static Future<void> verifyAll() => RelayHub.instance.verifyIdle();

  /// Prove quiet connections are still delivering, and repair them if not.
  Future<void> verifyIdleConnections() => RelayHub.instance.verifyIdle();

  void Function(String channelKey, String payload)? onMessageReceived;

  /// Called whenever a channel becomes usable, so queued work can be flushed.
  void Function(String channelKey)? onConnected;

  final Map<String, RelayConnectionState> _states = {};

  RelayConnectionState stateFor(String channelKey) =>
      _states[channelKey] ?? RelayConnectionState.disconnected;

  bool isConnected(String channelKey) =>
      stateFor(channelKey) == RelayConnectionState.connected;

  void _setState(String key, RelayConnectionState state) {
    if (_states[key] == state) return;
    _states[key] = state;
    notifyListeners();
  }


  // -- Sealed mailboxes -------------------------------------------------------

  /// Open a channel on [mailbox], identified locally by [channelKey].
  ///
  /// A channel can have several mailboxes behind it, one per device of the
  /// peer; [deviceKey] says which. Sends then name the device.
  Future<void> connectMailbox(String channelKey, Mailbox mailbox,
      {String? deviceKey}) async {
    _all.add(this);
    await RelayHub.instance
        .listen(RelayListener(this, channelKey), mailbox, deviceKey: deviceKey);
  }

  /// Hand a message to the relay.
  ///
  /// Returns false when there is no live socket. Callers must not treat that
  /// as delivered - OutboxService keeps the message queued and retries.
  Future<bool> sendViaRelay(String channelKey, String payload,
          {String? deviceKey}) async =>
      RelayHub.instance.publish(RelayListener(this, channelKey), payload,
          deviceKey: deviceKey);

  /// Hand one envelope per device to the relay. True if every one was taken.
  Future<bool> sendSealed(String channelKey, List<SealedForDevice> items) async {
    var all = true;
    for (final item in items) {
      final ok = await sendViaRelay(channelKey, item.sealed,
          deviceKey: item.deviceKey);
      all = all && ok;
    }
    return all && items.isNotEmpty;
  }

  // -- Handshake inbox --------------------------------------------------------

  /// Deliver a contact handshake to someone we share no secret with.
  ///
  /// Writes are unauthenticated by design - a stranger has no shared secret to
  /// sign with. Reads are not: see [syncInbox].
  Future<bool> postToInbox(String identityPublicKeyHex, String payload) async {
    final inboxId = Mailbox.inboxIdFor(identityPublicKeyHex);
    final hosts = RelayConfig.primaryHost == RelayConfig.defaultHost
        ? [RelayConfig.primaryHost, RelayConfig.fallbackHost]
        : [RelayConfig.primaryHost];
    for (final host in hosts) {
      try {
        final response = await http.post(
          Uri.parse('https://$host/inbox/$inboxId'),
          body: RelayHub.instance._pad(payload),
        );
        if (response.statusCode == 200) return true;
      } catch (e) {
        _log.warn('Relay', 'Inbox post failed on $host: $e');
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

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await relayHttp((host) => http.get(
            Uri.parse('https://$host$path/sync'),
            headers: {
              'X-Spheres-Signature':
                  _signWithIdentity('GET$path/sync$timestamp', myIdentitySecretHex),
              'X-Spheres-Timestamp': timestamp,
            },
          ));
      if (response.statusCode != 200) return const [];

      final pending = jsonDecode(response.body) as List<dynamic>;
      if (pending.isEmpty) return const [];

      final payloads = <String>[];
      final ids = <String>[];
      for (final msg in pending) {
        final payload = RelayHub.instance._unpad(msg['data'] as String);
        if (payload != null) payloads.add(payload);
        ids.add(msg['id'] as String);
      }

      final body = jsonEncode({'ids': ids});
      final ackTs = DateTime.now().millisecondsSinceEpoch.toString();
      await relayHttp((host) => http.post(
            Uri.parse('https://$host$path/ack'),
            headers: {
              'Content-Type': 'application/json',
              'X-Spheres-Signature':
                  _signWithIdentity('POST$path/ack$body$ackTs', myIdentitySecretHex),
              'X-Spheres-Timestamp': ackTs,
            },
            body: body,
          ));

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
      final response = await relayHttp((host) => http.post(
            Uri.parse('https://$host$path'),
            headers: {
              'X-Spheres-Signature': _signWithIdentity(
                  'POST$path$payload$timestamp', myIdentitySecretHex),
              'X-Spheres-Timestamp': timestamp,
            },
            body: payload,
          ));
      return response.statusCode == 200;
    } catch (e) {
      _log.error('Relay', 'Failed to publish prekey: $e');
      return false;
    }
  }

  /// Take our prekey bundle off the relay: the first step of leaving. True
  /// when the relay confirmed; false when it could not be reached, in which
  /// case the bundle ages out with the relay's retention.
  Future<bool> deletePrekey(String myIdentityPublicKeyHex, String myIdentitySecretHex) async {
    final address = Mailbox.inboxIdFor(myIdentityPublicKeyHex);
    final path = '/prekey/$address';
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await relayHttp((host) => http.delete(
            Uri.parse('https://$host$path'),
            headers: {
              'X-Spheres-Signature': _signWithIdentity('DELETE$path$timestamp', myIdentitySecretHex),
              'X-Spheres-Timestamp': timestamp,
            },
          ));
      return response.statusCode == 200;
    } catch (e) {
      _log.error('Relay', 'Could not delete the prekey bundle: $e');
      return false;
    }
  }

  Future<String?> fetchPrekey(String identityPublicKeyHex) async {
    final address = Mailbox.inboxIdFor(identityPublicKeyHex);
    try {
      final response = await relayHttp(
          (host) => http.get(Uri.parse('https://$host/prekey/$address')));
      return response.statusCode == 200 ? response.body : null;
    } catch (e) {
      _log.error('Relay', 'Failed to fetch prekey: $e');
      return null;
    }
  }

  // -- TURN -------------------------------------------------------------------

  /// Ask the relay for short-lived TURN credentials, proving we are a client
  /// by signing with any mailbox we hold. Null when the relay has none
  /// configured; the caller then says so rather than guessing.
  Future<Map<String, dynamic>?> fetchTurnCredentials(Mailbox anyMailbox) async {
    final path = '/turn/${anyMailbox.id}';
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await relayHttp((host) => http.get(
            Uri.parse('https://$host$path'),
            headers: {
              'X-Spheres-Signature': anyMailbox.sign('GET', path, '', timestamp),
              'X-Spheres-Timestamp': timestamp,
            },
          ));
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      _log.error('Relay', 'Failed to fetch TURN credentials: $e');
      return null;
    }
  }

  // -- Wake (push) ------------------------------------------------------------

  /// Tell the relay where to knock when mail arrives for [mailbox] and nobody
  /// is listening. [target] is a UnifiedPush endpoint or `apns:<token>`; null
  /// clears it. [keys] are the device's Web Push keys for that endpoint, when
  /// the distributor gave some, so the knock can carry an encrypted body.
  /// Returns an error message, or null on success.
  Future<String?> registerWake(Mailbox mailbox, String? target,
      [WakeKeys? keys]) async {
    final path = '/mbx/${mailbox.id}/wake';
    final body = jsonEncode({
      'url': target,
      if (keys != null && target != null) 'keys': keys.toJson(),
    });
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final response = await relayHttp((host) => http.post(
            Uri.parse('https://$host$path'),
            headers: {
              'Content-Type': 'application/json',
              'X-Spheres-Signature': mailbox.sign('POST', path, body, timestamp),
              'X-Spheres-Timestamp': timestamp,
            },
            body: body,
          ));
      if (response.statusCode == 200) return null;
      try {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        return decoded['error'] as String? ?? 'Relay answered ${response.statusCode}';
      } catch (_) {
        return 'Relay answered ${response.statusCode}';
      }
    } catch (e) {
      return 'Could not reach the relay: $e';
    }
  }

  /// The relay's VAPID public key, which a push distributor may require to
  /// accept knocks from it. Null when the relay has none configured; throws
  /// when the relay cannot be reached, so the caller can tell the two apart.
  Future<String?> vapidKey() async {
    final response = await relayHttp((host) => http.get(Uri.parse('https://$host/')));
    if (response.statusCode != 200) {
      throw StateError('Relay answered ${response.statusCode}');
    }
    final info = jsonDecode(response.body) as Map<String, dynamic>;
    final key = info['vapid'];
    return key is String && key.isNotEmpty ? key : null;
  }

  String _signWithIdentity(String message, String secretKeyHex) {
    final privKey = ed.PrivateKey(hex.decode(secretKeyHex));
    return hex.encode(ed.sign(privKey, utf8.encode(message)));
  }

  // -- Lifecycle --------------------------------------------------------------

  void disconnect(String channelKey) {
    RelayHub.instance.forget(RelayListener(this, channelKey));
    _states.remove(channelKey);
    notifyListeners();
  }

  void disconnectAll() {
    for (final key in _states.keys.toList()) {
      RelayHub.instance.forget(RelayListener(this, key));
    }
    _states.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _all.remove(this);
    disconnectAll();
    super.dispose();
  }
}

/// A publish the relay has not yet confirmed.
class _PendingSend {
  final String address;
  final Completer<bool> completer = Completer<bool>();
  _PendingSend(this.address);
}
