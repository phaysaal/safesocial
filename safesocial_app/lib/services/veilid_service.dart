import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import 'debug_log_service.dart';

/// Manages the Veilid node lifecycle and network state.
///
/// Provides access to the VeilidAPI and RoutingContext that all other
/// services need for DHT operations, identity management, and messaging.
class VeilidService extends ChangeNotifier {
  VeilidRoutingContext? _routingContext;
  StreamSubscription<VeilidUpdate>? _updateSubscription;

  bool _isInitialized = false;
  bool _isInitializing = false;
  bool _isFailed = false;
  bool _isAttached = false;
  AttachmentState _attachmentState = AttachmentState.detached;
  String? _error;
  String? _statePath;

  bool get isInitialized => _isInitialized;
  bool get isFailed => _isFailed;
  bool get isAttached => _isAttached;
  AttachmentState get attachmentState => _attachmentState;
  VeilidRoutingContext? get routingContext => _routingContext;
  String? get error => _error;

  /// Callback for DHT value change events — dispatched to ChatService/GroupService.
  void Function(RecordKey key, List<ValueSubkeyRange> subkeys)? onValueChange;

  /// Initialize the Veilid node and attach to the network.
  Future<void> initialize(String statePath) async {
    if (_isInitialized || _isInitializing) return;

    _statePath = statePath;
    _isInitializing = true;
    _isFailed = false;
    _error = null;

    try {
      // Step 1: Initialize the FFI bridge (native library must be loaded first).
      // On web this is not needed.
      if (!kIsWeb) {
        const platformConfig = VeilidFFIConfig(
          logging: VeilidFFIConfigLogging(
            terminal: VeilidFFIConfigLoggingTerminal(
                enabled: false, level: VeilidConfigLogLevel.debug),
            otlp: VeilidFFIConfigLoggingOtlp(
                enabled: false,
                level: VeilidConfigLogLevel.debug,
                grpcEndpoint: '',
                serviceName: 'spheres'),
            api: VeilidFFIConfigLoggingApi(
                enabled: true, level: VeilidConfigLogLevel.info),
            flame: VeilidFFIConfigLoggingFlame(
                enabled: false, path: ''),
          ),
        );
        try {
          Veilid.instance.initializeVeilidCore(platformConfig.toJson());
          DebugLogService().info('Veilid', 'FFI bridge initialized');
        } catch (e) {
          // Only safe to ignore if already initialized — log everything else.
          final msg = e.toString();
          if (!msg.contains('already')) {
            DebugLogService().warn('Veilid', 'initializeVeilidCore: $msg');
          }
        }
      }

      // Step 2: Build config with our storage paths.
      final config = await getDefaultVeilidConfig(
        isWeb: kIsWeb,
        programName: 'spheres',
        namespace: '',
        deviceEncryptionKeyPassword: '',
      ).then((c) => c.copyWith(
        tableStore: c.tableStore.copyWith(directory: '$statePath/table_store'),
        blockStore: c.blockStore.copyWith(directory: '$statePath/block_store'),
        protectedStore: c.protectedStore.copyWith(directory: '$statePath/protected_store'),
      ));

      // Step 3: Start the core — with a hard timeout so we never hang forever.
      DebugLogService().info('Veilid', 'Starting core…');
      final updateStream = await Future.any([
        Veilid.instance.startupVeilidCore(config),
        Future.delayed(const Duration(seconds: 20))
            .then((_) => throw TimeoutException('startupVeilidCore timed out after 20s')),
      ]);

      _updateSubscription = updateStream.listen(
        _handleUpdate,
        onError: (e) {
          DebugLogService().error('Veilid', 'Update stream error: $e');
          _error = e.toString();
          notifyListeners();
        },
      );

      // Step 4: Attach to the network (non-blocking — attachment state comes via updates).
      DebugLogService().info('Veilid', 'Calling attach()…');
      await Veilid.instance.attach();
      DebugLogService().info('Veilid', 'attach() returned — waiting for network…');

      // Step 5: Create a basic routing context (with timeout — can hang on some devices).
      DebugLogService().info('Veilid', 'Creating routing context…');
      _routingContext = await Future.any([
        Veilid.instance.routingContext(),
        Future.delayed(const Duration(seconds: 10))
            .then((_) => throw TimeoutException('routingContext() timed out after 10s')),
      ]);

      _isInitialized = true;
      _isInitializing = false;
      DebugLogService().success('Veilid', 'Ready — watching for peers…');
      notifyListeners();
    } on TimeoutException catch (e) {
      _isInitializing = false;
      _isFailed = true;
      _error = e.message ?? 'Startup timed out';
      DebugLogService().error('Veilid', _error!);
      notifyListeners();
      rethrow;
    } catch (e) {
      _isInitializing = false;
      _isFailed = true;
      _error = e.toString();
      DebugLogService().error('Veilid', 'Initialization failed: $e');
      notifyListeners();
      rethrow;
    }
  }

  /// Retry initialization after a failure — called from the UI retry button.
  Future<void> retryInitialize() async {
    if (_isInitialized || _statePath == null) return;
    await initialize(_statePath!);
  }

  /// Wipe Veilid state directories and retry — use when ProtectedStore is corrupted.
  Future<void> clearStateAndRetry() async {
    if (_isInitialized || _statePath == null) return;
    DebugLogService().warn('Veilid', 'Clearing corrupted state at $_statePath…');
    try {
      final dir = Directory(_statePath!);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await Directory(_statePath!).create(recursive: true);
      await Directory('$_statePath/protected_store').create(recursive: true);
      await Directory('$_statePath/table_store').create(recursive: true);
      await Directory('$_statePath/block_store').create(recursive: true);
      DebugLogService().info('Veilid', 'State cleared — retrying…');
    } catch (e) {
      DebugLogService().error('Veilid', 'Failed to clear state: $e');
    }
    await initialize(_statePath!);
  }

  /// Returns true if the error looks like a ProtectedStore corruption.
  bool get isProtectedStoreError =>
      _error != null &&
      (_error!.toLowerCase().contains('protected store') ||
       _error!.toLowerCase().contains('protectedstore'));

  /// Shut down the Veilid node and release resources.
  Future<void> shutdown() async {
    if (!_isInitialized) return;

    try {
      _routingContext?.close();
      _routingContext = null;

      await _updateSubscription?.cancel();
      _updateSubscription = null;

      await Veilid.instance.shutdownVeilidCore();

      _isAttached = false;
      _isInitialized = false;
      _isInitializing = false;
      _isFailed = false;
      _attachmentState = AttachmentState.detached;
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Veilid', 'Shutdown error: $e');
    }
  }

  /// Wait until the node is initialized (safe to use Veilid.instance).
  Future<bool> waitForInit({Duration timeout = const Duration(seconds: 15)}) async {
    if (_isInitialized) return true;

    final completer = Completer<bool>();
    Timer? timer;

    void listener() {
      if (_isInitialized && !completer.isCompleted) {
        timer?.cancel();
        completer.complete(true);
      }
    }

    addListener(listener);
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    try {
      return await completer.future;
    } finally {
      removeListener(listener);
      timer.cancel();
    }
  }

  /// Wait until the node is attached to the network (or timeout).
  Future<bool> waitForAttach(
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (_isAttached) return true;

    final completer = Completer<bool>();
    Timer? timer;

    void listener() {
      if (_isAttached && !completer.isCompleted) {
        timer?.cancel();
        completer.complete(true);
      }
    }

    addListener(listener);
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    try {
      return await completer.future;
    } finally {
      removeListener(listener);
      timer.cancel();
    }
  }

  /// Handle incoming VeilidUpdate events from the network.
  void _handleUpdate(VeilidUpdate update) {
    switch (update) {
      case VeilidUpdateAttachment(:final state):
        final wasState = _attachmentState;
        _attachmentState = state;
        _isAttached = state == AttachmentState.attachedWeak ||
            state == AttachmentState.attachedGood ||
            state == AttachmentState.attachedStrong ||
            state == AttachmentState.fullyAttached ||
            state == AttachmentState.overAttached;
        // Log every state change so the onboarding log panel shows progress
        if (state != wasState) {
          if (_isAttached) {
            DebugLogService().success('Veilid', 'Network: $state');
          } else {
            DebugLogService().info('Veilid', 'Network: $state');
          }
        }
        notifyListeners();

      case VeilidUpdateNetwork(:final started, :final peers):
        if (started) {
          DebugLogService().info('Veilid', 'Network active — peers: ${peers.length}');
        }

      case VeilidUpdateValueChange(:final key, :final subkeys):
        DebugLogService().info('Veilid', 'DHT value changed: $key subkeys=$subkeys');
        onValueChange?.call(key, subkeys);

      case VeilidLog(:final message, :final logLevel):
        if (logLevel == VeilidLogLevel.error) {
          DebugLogService().error('Veilid', message);
        }

      default:
        break;
    }
  }

  @override
  void dispose() {
    shutdown();
    super.dispose();
  }
}
