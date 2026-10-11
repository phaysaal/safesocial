import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../crypto/mailbox.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

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
  /// arrive through [onEndpoint], possibly later and possibly again.
  Future<void> start({
    required void Function(String instance, String? target) onEndpoint,
    required void Function() onWake,
  });

  Future<void> register(String instance);
  Future<void> unregister(String instance);
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
  late final Future<String?> Function(Mailbox mailbox, String? target)
      _registerWithRelay;

  bool _enabled = true;
  bool _started = false;

  /// instance (mailbox id) → target the relay was told about.
  final Map<String, String> _registered = {};

  /// Mailboxes the hub currently holds, by id.
  final Map<String, Mailbox> _mailboxes = {};

  /// Called on a wake; the app syncs.
  void Function()? onWake;

  WakeService({
    required this.provider,
    RelayService? relay,
    Future<String?> Function(Mailbox mailbox, String? target)? registerWithRelay,
  }) : _relay = relay ?? RelayService() {
    _registerWithRelay = registerWithRelay ?? _relay.registerWake;
  }

  bool get enabled => _enabled;
  bool get started => _started;
  int get registeredCount => _registered.length;
  Map<String, String> get registered => Map.unmodifiable(_registered);

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
      RelayHub.instance.onSubscribed = _onSubscribed;
      RelayHub.instance.onForgotten = _onForgotten;
      await provider.start(
        onEndpoint: (instance, target) => unawaited(_onEndpoint(instance, target)),
        onWake: () => onWake?.call(),
      );
    }
    // Everything the hub holds right now, including anything subscribed while
    // this was switched off. Registering twice is harmless.
    for (final mailbox in RelayHub.instance.mailboxes) {
      _onSubscribed(mailbox);
    }
    notifyListeners();
  }

  void _onSubscribed(Mailbox mailbox) {
    if (!_enabled || !_started) return;
    _mailboxes[mailbox.id] = mailbox;
    unawaited(provider.register(mailbox.id));
  }

  void _onForgotten(Mailbox mailbox) {
    _mailboxes.remove(mailbox.id);
    if (_registered.remove(mailbox.id) != null) {
      unawaited(_registerWithRelay(mailbox, null));
    }
    unawaited(provider.unregister(mailbox.id));
  }

  /// The provider has an endpoint for [instance]; tell the relay.
  Future<void> _onEndpoint(String instance, String? target) async {
    final mailbox = _mailboxes[instance];
    if (mailbox == null) {
      DebugLogService().warn('Wake', 'Endpoint for a mailbox we no longer hold');
      return;
    }
    if (target == null) {
      _registered.remove(instance);
      await _registerWithRelay(mailbox, null);
      notifyListeners();
      return;
    }
    if (_registered[instance] == target) return;

    final error = await _registerWithRelay(mailbox, target);
    if (error != null) {
      DebugLogService().error('Wake', 'Relay refused wake target: $error');
      lastError = error;
    } else {
      _registered[instance] = target;
      lastError = null;
      DebugLogService().success('Wake',
          'Relay will knock on ${provider.name} for a mailbox (${_registered.length} registered)');
    }
    notifyListeners();
  }

  /// The last refusal from the relay, for Settings. Null when all is well.
  String? lastError;

  Future<void> _clearAll() async {
    for (final entry in _registered.entries.toList()) {
      final mailbox = _mailboxes[entry.key];
      if (mailbox != null) await _registerWithRelay(mailbox, null);
      await provider.unregister(entry.key);
    }
    _registered.clear();
  }
}

/// UnifiedPush: an open standard with a distributor app the user chooses.
///
/// The default build carries no Google SDK. A user who wants Google's
/// delivery installs the UnifiedPush FCM distributor; this code is the same.
class UnifiedPushWakeProvider implements WakeProvider {
  @override
  String get name => 'UnifiedPush';

  /// The distributor in use, for Settings.
  String? distributor;

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
        'another distributor) from F-Droid or Google Play, then come back here.';
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

  void Function(String instance, String? target)? _onEndpoint;
  void Function()? _onWake;

  @override
  Future<void> start({
    required void Function(String instance, String? target) onEndpoint,
    required void Function() onWake,
  }) async {
    _onEndpoint = onEndpoint;
    _onWake = onWake;
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, instance) =>
          _onEndpoint?.call(instance, endpoint.url),
      onRegistrationFailed: (reason, instance) {
        DebugLogService().warn('Wake', 'Registration failed for $instance: $reason');
        _onEndpoint?.call(instance, null);
      },
      onUnregistered: (instance) => _onEndpoint?.call(instance, null),
      onMessage: (message, instance) => _onWake?.call(),
    );
    if (await UnifiedPush.getDistributor() == null) {
      await UnifiedPush.tryUseCurrentOrDefaultDistributor();
    }
    distributor = await UnifiedPush.getDistributor();
  }

  @override
  Future<void> register(String instance) => UnifiedPush.register(instance: instance);

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
  void Function(String instance, String? target)? _onEndpoint;
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
    required void Function(String instance, String? target) onEndpoint,
    required void Function() onWake,
  }) async {
    _onEndpoint = onEndpoint;
    _onWake = onWake;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'token':
          _token = call.arguments as String?;
          for (final instance in _instances) {
            _onEndpoint?.call(instance, _target);
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
    if (_token != null) _onEndpoint?.call(instance, _target);
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
    required void Function(String instance, String? target) onEndpoint,
    required void Function() onWake,
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
