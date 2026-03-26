import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

/// Manages the Veilid node lifecycle and network state.
///
/// Provides access to the VeilidAPI and RoutingContext that all other
/// services need for DHT operations, identity management, and messaging.
class VeilidService extends ChangeNotifier {
  VeilidRoutingContext? _routingContext;
  StreamSubscription<VeilidUpdate>? _updateSubscription;

  bool _isInitialized = false;
  bool _isAttached = false;
  AttachmentState _attachmentState = AttachmentState.detached;
  String? _error;

  bool get isInitialized => _isInitialized;
  bool get isAttached => _isAttached;
  AttachmentState get attachmentState => _attachmentState;
  VeilidRoutingContext? get routingContext => _routingContext;
  String? get error => _error;

  /// Callback for DHT value change events — dispatched to ChatService/GroupService.
  void Function(RecordKey key, List<ValueSubkeyRange> subkeys)? onValueChange;

  /// Initialize the Veilid node and attach to the network.
  Future<void> initialize(String statePath) async {
    if (_isInitialized) return;

    try {
      _error = null;

      final config = await getDefaultVeilidConfig(
        isWeb: kIsWeb,
        programName: 'spheres',
        namespace: '',
        deviceEncryptionKeyPassword: '',
      );

      final updateStream = await Veilid.instance.startupVeilidCore(config);

      _updateSubscription = updateStream.listen(
        _handleUpdate,
        onError: (e) {
          debugPrint('[VeilidService] Update stream error: $e');
          _error = e.toString();
          notifyListeners();
        },
      );

      await Veilid.instance.attach();

      _routingContext = await Veilid.instance.safeRoutingContext(
        sequencing: Sequencing.preferOrdered,
      );

      _isInitialized = true;
      debugPrint('[VeilidService] Initialized and attaching...');
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      debugPrint('[VeilidService] Initialization failed: $e');
      notifyListeners();
      rethrow;
    }
  }

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
      _attachmentState = AttachmentState.detached;
      notifyListeners();
    } catch (e) {
      debugPrint('[VeilidService] Shutdown error: $e');
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
        _attachmentState = state;
        _isAttached = state == AttachmentState.attachedWeak ||
            state == AttachmentState.attachedGood ||
            state == AttachmentState.attachedStrong ||
            state == AttachmentState.fullyAttached ||
            state == AttachmentState.overAttached;
        debugPrint('[VeilidService] Attachment: $state');
        notifyListeners();

      case VeilidUpdateNetwork(:final started, :final peers):
        debugPrint(
            '[VeilidService] Network: started=$started, peers=${peers.length}');

      case VeilidUpdateValueChange(:final key, :final subkeys):
        debugPrint('[VeilidService] Value changed: $key subkeys=$subkeys');
        onValueChange?.call(key, subkeys);

      case VeilidLog(:final message, :final logLevel):
        if (logLevel == VeilidLogLevel.error) {
          debugPrint('[Veilid] ERROR: $message');
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
