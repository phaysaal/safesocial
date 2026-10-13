import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../crypto/mailbox.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// The device's Web Push keys for one endpoint (RFC 8291): the relay encrypts
/// its knock to them. Google's push service drops a push with no bytes, so
/// without these a knock through it would never arrive; ntfy does not care.
@immutable
class WakeKeys {
  /// Uncompressed P-256 point, base64url.
  final String p256dh;

  /// 16-byte auth secret, base64url.
  final String auth;

  const WakeKeys({required this.p256dh, required this.auth});

  Map<String, String> toJson() => {'p256dh': p256dh, 'auth': auth};

  @override
  bool operator ==(Object other) =>
      other is WakeKeys && other.p256dh == p256dh && other.auth == auth;

  @override
  int get hashCode => Object.hash(p256dh, auth);
}

/// Something that can wake this device when the relay has mail for it.
///
/// A wake carries nothing. Whoever runs the provider learns that *this
/// endpoint* was poked and when; the content stays on the relay until the
/// app fetches it over its own authenticated connection. See §12.1 of the
/// rebuild plan for why this is the chosen shape.
abstract class WakeProvider {
  /// Short name for Settings.
  String get name;

  /// Whether this provider can work on this device at all.
  Future<bool> get isAvailable;

  /// Human-readable reason when it cannot, for Settings.
  Future<String?> get unavailableReason;

  /// Start, and ask for an endpoint per [instance] (one per mailbox on
  /// UnifiedPush, so the relay cannot link mailboxes to one device). Endpoints
  /// arrive through [onEndpoint], possibly later and possibly again, with the
  /// device's Web Push keys when the provider has them. A registration the
  /// provider could not make is reported through [onFailed] with the reason
  /// the distributor gave. [vapid] is the relay's VAPID public key, which a
  /// distributor may insist on (Google's does); null when the relay has none
  /// or could not be asked.
  Future<void> start({
    required void Function(String instance, String? target, WakeKeys? keys)
        onEndpoint,
    required void Function() onWake,
    void Function(String instance, WakeFailure reason)? onFailed,
    String? vapid,
  });

  Future<void> register(String instance);
  Future<void> unregister(String instance);
}

/// Why a distributor refused a registration, in the words of the UnifiedPush
/// specification.
enum WakeFailure {
  /// Try again directly.
  internalError,

  /// No network; try again when it is back.
  network,

  /// The distributor wants the person to do something (log in, allow it, or
  /// for the built-in Google one: Google Play services is missing).
  actionRequired,

  /// The distributor needs a VAPID key and none was given: the relay has none
  /// or was unreachable when registering.
  vapidRequired,
}

/// Registers wake targets with the relay for every mailbox the hub holds.
///
/// Per mailbox because that is what the relay knows: a mailbox object stores
/// one wake target and knocks on it when mail arrives and nobody is listening.
class WakeService extends ChangeNotifier {
  static const _enabledKey = 'spheres_wake_enabled';

  final WakeProvider provider;
  final RelayService _relay;

  /// How a wake target reaches the relay. Replaceable for tests.
  late final Future<String?> Function(
      Mailbox mailbox, String? target, WakeKeys? keys) _registerWithRelay;

  /// How the relay's VAPID public key is fetched. Replaceable for tests.
  late final Future<String?> Function() _fetchVapid;

  bool _enabled = true;
  bool _started = false;

  /// instance (mailbox id) → target the relay was told about.
  final Map<String, String> _registered = {};

  /// Mailboxes the hub currently holds, by id.
  final Map<String, Mailbox> _mailboxes = {};

  /// The relay's VAPID public key, once fetched.
  String? _vapid;

  /// Called on a wake; the app syncs.
  void Function()? onWake;

  WakeService({
    required this.provider,
    RelayService? relay,
    Future<String?> Function(Mailbox mailbox, String? target, WakeKeys? keys)?
        registerWithRelay,
    Future<String?> Function()? fetchVapid,
  }) : _relay = relay ?? RelayService() {
    _registerWithRelay = registerWithRelay ?? _relay.registerWake;
    _fetchVapid = fetchVapid ?? _relay.vapidKey;
  }

  bool get enabled => _enabled;
  bool get started => _started;
  int get registeredCount => _registered.length;
  Map<String, String> get registered => Map.unmodifiable(_registered);

  /// The relay's VAPID public key as last fetched; null when the relay has
  /// none or has not answered yet.
  String? get vapid => _vapid;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    (await SharedPreferences.getInstance()).setBool(_enabledKey, value);
    if (value) {
      await start();
    } else {
      await _clearAll();
    }
    notifyListeners();
  }

  /// Attach to the hub and start the provider.
  Future<void> start() async {
    if (!_enabled) return;
    if (!await provider.isAvailable) {
      DebugLogService().info('Wake', '${provider.name} not available: '
          '${await provider.unavailableReason}');
      notifyListeners();
      return;
    }
    if (!_started) {
      _started = true;
      _vapid ??= await _askRelayForVapid();
      RelayHub.instance.onSubscribed = _onSubscribed;
      RelayHub.instance.onForgotten = _onForgotten;
      await provider.start(
        onEndpoint: (instance, target, keys) =>
            unawaited(_onEndpoint(instance, target, keys)),
        onWake: () => onWake?.call(),
        onFailed: (instance, reason) => unawaited(_onFailed(instance, reason)),
        vapid: _vapid,
      );
    }
    // Everything the hub holds right now, including anything subscribed while
    // this was switched off. Registering twice is harmless.
    for (final mailbox in RelayHub.instance.mailboxes) {
      _onSubscribed(mailbox);
    }
    notifyListeners();
  }

  Future<String?> _askRelayForVapid() async {
    try {
      final key = await _fetchVapid();
      if (key == null) {
        DebugLogService().info('Wake', 'The relay has no VAPID key');
      }
      return key;
    } catch (e) {
      DebugLogService().warn('Wake', 'Could not ask the relay for its VAPID key: $e');
      return null;
    }
  }

  void _onSubscribed(Mailbox mailbox) {
    if (!_enabled || !_started) return;
    _mailboxes[mailbox.id] = mailbox;
    // Once per process. The hub resubscribes on every reconnect and a wake
    // starts the services again; neither needs a new endpoint. Switching
    // distributor or switching off clears [_registered], so those do.
    if (_registered.containsKey(mailbox.id) || _asked.contains(mailbox.id)) {
      return;
    }
    _enqueue(mailbox.id);
  }

  /// Instances asked for in this process whose answer has not been a refusal
  /// or a withdrawal; a resubscribe while the answer is in flight asks nothing.
  final Set<String> _asked = {};

  // Registrations go to the distributor one at a time. Seen on the tablet
  // with the built-in Google distributor: five fired together and one timed
  // out inside Play services' IPC; a later burst into a process the system
  // had frozen overflowed its binder buffer and the process crashed with the
  // knock unhandled.
  final List<String> _queue = [];
  final Set<String> _queued = {};
  bool _draining = false;
  Completer<void>? _idle;
  String? _asking;
  Completer<void>? _answer;
  final Set<String> _retried = {};

  /// How long one registration waits for the distributor's answer before the
  /// next goes out.
  @visibleForTesting
  static Duration registerTimeout = const Duration(seconds: 10);

  /// How long an internal error waits before its one retry.
  @visibleForTesting
  static Duration retryDelay = const Duration(seconds: 3);

  /// Completes when nothing is waiting to be registered.
  @visibleForTesting
  Future<void> get registrationsSettled => _idle?.future ?? Future.value();

  void _enqueue(String instance) {
    if (_queued.add(instance)) _queue.add(instance);
    if (!_draining) unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    _idle = Completer<void>();
    try {
      while (_queue.isNotEmpty) {
        final instance = _queue.removeAt(0);
        _queued.remove(instance);
        if (!_mailboxes.containsKey(instance)) continue;
        final answer = Completer<void>();
        _asking = instance;
        _answer = answer;
        try {
          _asked.add(instance);
          await provider.register(instance);
          await answer.future.timeout(registerTimeout, onTimeout: () {});
        } catch (e) {
          DebugLogService().warn('Wake', 'Registration could not be sent: $e');
        } finally {
          _asking = null;
          _answer = null;
        }
      }
    } finally {
      _draining = false;
      _idle?.complete();
    }
  }

  /// The distributor answered for [instance], one way or the other.
  void _answered(String instance) {
    final answer = _answer;
    if (_asking == instance && answer != null && !answer.isCompleted) {
      answer.complete();
    }
  }

  void _onForgotten(Mailbox mailbox) {
    _mailboxes.remove(mailbox.id);
    if (_registered.remove(mailbox.id) != null) {
      unawaited(_registerWithRelay(mailbox, null, null));
    }
    unawaited(provider.unregister(mailbox.id));
  }

  /// Move every registration to another UnifiedPush distributor: the old
  /// one's registrations are withdrawn first, so it stops holding endpoints
  /// nobody knocks on, and the new one's endpoints overwrite the relay's
  /// targets as they arrive. The old distributor's "unregistered" answers
  /// may come after the new endpoints; while switching they are not allowed
  /// to clear anything at the relay.
  Future<void> switchDistributor(String id) async {
    final provider = this.provider;
    if (provider is! UnifiedPushWakeProvider) return;
    _switching = true;
    try {
      for (final instance in _mailboxes.keys.toList()) {
        await provider.unregister(instance);
      }
      _registered.clear();
      _asked.clear();
      await provider.useDistributor(id);
      await Future<void>.delayed(switchSettle);
      for (final mailbox in _mailboxes.values.toList()) {
        _enqueue(mailbox.id);
      }
      await registrationsSettled;
      await Future<void>.delayed(switchSettle);
    } finally {
      _switching = false;
    }
    notifyListeners();
  }

  bool _switching = false;

  /// How long a switch waits for the old distributor's answers to pass.
  @visibleForTesting
  static Duration switchSettle = const Duration(seconds: 2);

  /// The provider has an endpoint for [instance]; tell the relay.
  Future<void> _onEndpoint(String instance, String? target, WakeKeys? keys) async {
    _answered(instance);
    final mailbox = _mailboxes[instance];
    if (mailbox == null) {
      DebugLogService().warn('Wake', 'Endpoint for a mailbox we no longer hold');
      return;
    }
    if (target == null) {
      _registered.remove(instance);
      _asked.remove(instance);
      if (!_switching) await _registerWithRelay(mailbox, null, null);
      notifyListeners();
      return;
    }
    if (_registered[instance] == target) return;

    final error = await _registerWithRelay(mailbox, target, keys);
    if (error != null) {
      DebugLogService().error('Wake', 'Relay refused wake target: $error');
      lastError = error;
    } else {
      _registered[instance] = target;
      _retried.remove(instance);
      lastError = null;
      DebugLogService().success('Wake',
          'Relay will knock on ${provider.name} for a mailbox (${_registered.length} registered)');
    }
    notifyListeners();
  }

  /// The distributor refused a registration. A VAPID refusal when we had no
  /// key is retried once with a fresh answer from the relay, since the first
  /// ask may have found it unreachable; anything else is for Settings.
  Future<void> _onFailed(String instance, WakeFailure reason) async {
    _answered(instance);
    _registered.remove(instance);
    _asked.remove(instance);
    if (reason == WakeFailure.internalError && _retried.add(instance)) {
      // On the tablet this was Play services' IPC timing out under a burst;
      // one more go, on its own, has been enough.
      DebugLogService().warn('Wake',
          '${provider.name} could not register a mailbox; trying once more');
      await Future<void>.delayed(retryDelay);
      if (_mailboxes.containsKey(instance)) _enqueue(instance);
      return;
    }
    if (reason == WakeFailure.vapidRequired && _vapid == null && !_retriedVapid) {
      _retriedVapid = true;
      _vapid = await _askRelayForVapid();
      if (_vapid != null) {
        DebugLogService().info('Wake', 'Got the relay\'s VAPID key; registering again');
        await provider.start(
          onEndpoint: (i, t, k) => unawaited(_onEndpoint(i, t, k)),
          onWake: () => onWake?.call(),
          onFailed: (i, r) => unawaited(_onFailed(i, r)),
          vapid: _vapid,
        );
        _enqueue(instance);
        return;
      }
    }
    lastError = describeFailure(reason, provider);
    DebugLogService().error('Wake', 'Registration refused: $lastError');
    notifyListeners();
  }

  bool _retriedVapid = false;

  /// The refusal in words for Settings.
  static String describeFailure(WakeFailure reason, WakeProvider provider) {
    final builtIn = provider is UnifiedPushWakeProvider && provider.usesEmbedded;
    switch (reason) {
      case WakeFailure.internalError:
        return '${provider.name} could not register this phone; it will try again at the next start.';
      case WakeFailure.network:
        return '${provider.name} had no network; it will try again when it is back.';
      case WakeFailure.actionRequired:
        return builtIn
            ? 'Google Play services is missing or needs an update on this phone.'
            : '${provider.name} needs you to open it and allow Spheres.';
      case WakeFailure.vapidRequired:
        return '${provider.name} needs a signing key from the relay, and the relay has none '
            '(or could not be reached). Ask the relay operator to set VAPID keys.';
    }
  }

  /// The last refusal, from the relay or the distributor, for Settings. Null
  /// when all is well.
  String? lastError;

  Future<void> _clearAll() async {
    _queue.clear();
    _queued.clear();
    _asked.clear();
    for (final entry in _registered.entries.toList()) {
      final mailbox = _mailboxes[entry.key];
      if (mailbox != null) await _registerWithRelay(mailbox, null, null);
      await provider.unregister(entry.key);
    }
    _registered.clear();
  }
}

/// UnifiedPush: an open standard with a distributor app the user chooses.
///
/// The `foss` build carries no Google code at all and needs a distributor
/// such as ntfy installed. The `play` build embeds the UnifiedPush FCM
/// distributor, which registers with Google Play services the way a browser
/// does (the relay's VAPID key as the sender; no Firebase project, no Google
/// SDK) and so wakes through Google with nothing else installed. An external
/// distributor, when one is installed, is preferred over the built-in one.
/// Either way the code here is the same.
class UnifiedPushWakeProvider implements WakeProvider {
  /// The id the built-in distributor answers to: our own package.
  static const embeddedDistributor = 'com.spheres.spheres_app';

  /// A distributor id in words.
  static String describe(String id) =>
      id == embeddedDistributor ? 'Google Play services (built in)' : id;

  @override
  String get name => usesEmbedded ? 'Google Play services' : 'UnifiedPush';

  /// The distributor in use, for Settings.
  String? distributor;

  bool get usesEmbedded => distributor == embeddedDistributor;

  @override
  Future<bool> get isAvailable async {
    if (!Platform.isAndroid) return false;
    try {
      return (await UnifiedPush.getDistributors()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> get unavailableReason async {
    if (!Platform.isAndroid) return 'UnifiedPush is for Android.';
    return 'No UnifiedPush distributor is installed. Install ntfy (or '
        'another distributor) from F-Droid or Google Play, then come back here'
        '${appFlavor == 'foss' ? '; the Google Play build of Spheres can wake through Google Play services instead' : ''}.';
  }

  Future<List<String>> distributors() async {
    try {
      return await UnifiedPush.getDistributors();
    } catch (_) {
      return const [];
    }
  }

  Future<void> useDistributor(String id) async {
    await UnifiedPush.saveDistributor(id);
    distributor = id;
  }

  void Function(String instance, String? target, WakeKeys? keys)? _onEndpoint;
  void Function()? _onWake;
  void Function(String instance, WakeFailure reason)? _onFailed;
  String? _vapid;
  bool _initialised = false;

  @override
  Future<void> start({
    required void Function(String instance, String? target, WakeKeys? keys)
        onEndpoint,
    required void Function() onWake,
    void Function(String instance, WakeFailure reason)? onFailed,
    String? vapid,
  }) async {
    _onEndpoint = onEndpoint;
    _onWake = onWake;
    _onFailed = onFailed;
    _vapid = vapid;
    if (_initialised) return;
    _initialised = true;
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, instance) {
        final set = endpoint.pubKeySet;
        _onEndpoint?.call(
          instance,
          endpoint.url,
          set == null ? null : WakeKeys(p256dh: set.pubKey, auth: set.auth),
        );
      },
      onRegistrationFailed: (reason, instance) {
        DebugLogService().warn('Wake', 'Registration failed for $instance: $reason');
        _onEndpoint?.call(instance, null, null);
        _onFailed?.call(instance, _failure(reason));
      },
      onUnregistered: (instance) => _onEndpoint?.call(instance, null, null),
      onMessage: (message, instance) => _onWake?.call(),
    );
    if (await UnifiedPush.getDistributor() == null) {
      await UnifiedPush.tryUseCurrentOrDefaultDistributor();
    }
    if (await UnifiedPush.getDistributor() == null) {
      // No default and no picker answer (a headless start has no activity
      // to show one): with exactly one distributor there is nothing to ask.
      final all = await distributors();
      if (all.length == 1) await UnifiedPush.saveDistributor(all.single);
    }
    distributor = await UnifiedPush.getDistributor();
  }

  static WakeFailure _failure(FailedReason reason) {
    switch (reason) {
      case FailedReason.network:
        return WakeFailure.network;
      case FailedReason.actionRequired:
        return WakeFailure.actionRequired;
      case FailedReason.vapidRequired:
        return WakeFailure.vapidRequired;
      case FailedReason.internalError:
        return WakeFailure.internalError;
    }
  }

  @override
  Future<void> register(String instance) =>
      UnifiedPush.register(instance: instance, vapid: _vapid);

  @override
  Future<void> unregister(String instance) => UnifiedPush.unregister(instance);
}

/// Apple Push Notification service, through a small native bridge in the iOS
/// runner. One device token for everything, so on iOS the relay can see that
/// several mailboxes wake the same device; recorded in the threat model.
class ApnsWakeProvider implements WakeProvider {
  static const _channel = MethodChannel('spheres/apns');

  String? _token;
  final Set<String> _instances = {};
  void Function(String instance, String? target, WakeKeys? keys)? _onEndpoint;
  void Function()? _onWake;

  @override
  String get name => 'Apple Push';

  @override
  Future<bool> get isAvailable async => Platform.isIOS;

  @override
  Future<String?> get unavailableReason async =>
      Platform.isIOS ? null : 'Apple Push is for iOS.';

  @override
  Future<void> start({
    required void Function(String instance, String? target, WakeKeys? keys)
        onEndpoint,
    required void Function() onWake,
    void Function(String instance, WakeFailure reason)? onFailed,
    String? vapid,
  }) async {
    _onEndpoint = onEndpoint;
    _onWake = onWake;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'token':
          _token = call.arguments as String?;
          for (final instance in _instances) {
            _onEndpoint?.call(instance, _target, null);
          }
        case 'wake':
          _onWake?.call();
      }
    });
    try {
      _token = await _channel.invokeMethod<String>('register');
    } on MissingPluginException {
      DebugLogService().error('Wake', 'APNs bridge missing from the iOS runner');
    } on PlatformException catch (e) {
      DebugLogService().error('Wake', 'APNs registration failed: ${e.message}');
    }
  }

  String? get _target => _token == null ? null : 'apns:$_token';

  @override
  Future<void> register(String instance) async {
    _instances.add(instance);
    if (_token != null) _onEndpoint?.call(instance, _target, null);
  }

  @override
  Future<void> unregister(String instance) async {
    _instances.remove(instance);
  }
}

/// For desktops and tests: nothing can wake us, and says so.
class NoWakeProvider implements WakeProvider {
  final String reason;
  const NoWakeProvider([this.reason = 'Background wake is not available on this platform.']);

  @override
  String get name => 'None';
  @override
  Future<bool> get isAvailable async => false;
  @override
  Future<String?> get unavailableReason async => reason;
  @override
  Future<void> start({
    required void Function(String instance, String? target, WakeKeys? keys)
        onEndpoint,
    required void Function() onWake,
    void Function(String instance, WakeFailure reason)? onFailed,
    String? vapid,
  }) async {}
  @override
  Future<void> register(String instance) async {}
  @override
  Future<void> unregister(String instance) async {}
}

/// The right provider for this platform.
WakeProvider defaultWakeProvider() {
  if (Platform.isAndroid) return UnifiedPushWakeProvider();
  if (Platform.isIOS) return ApnsWakeProvider();
  return const NoWakeProvider();
}
