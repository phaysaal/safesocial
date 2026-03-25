// Real implementation uses package:veilid/veilid.dart for P2P networking.
// Veilid types used: VeilidAPI, VeilidRoutingContext, VeilidUpdate,
// AttachmentState, RecordKey, ValueSubkeyRange, Sequencing, VeilidLogLevel.
// Stubbed out until Android NDK + Rust toolchain issues are resolved.
// See pubspec.yaml for the veilid dependency (currently commented out).

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Manages the Veilid node lifecycle and network state.
///
/// This is a stub implementation that preserves the public API surface.
/// When the veilid package compiles for Android, restore the real
/// implementation from version control.
class VeilidService extends ChangeNotifier {
  // In the real implementation, this is a VeilidRoutingContext.
  // void Function(RecordKey key, List<ValueSubkeyRange> subkeys)? onValueChange;
  // — stubbed as dynamic since those types come from the veilid package.
  void Function(String key, List<dynamic> subkeys)? onValueChange;

  bool _isInitialized = false;
  bool _isAttached = false;
  String? _error;

  bool get isInitialized => _isInitialized;
  bool get isAttached => _isAttached;
  String? get error => _error;

  // In the real implementation this returns a VeilidRoutingContext.
  // Other services check for null to know if Veilid is ready.
  dynamic get routingContext => null;

  /// Initialize the Veilid node and attach to the network.
  ///
  /// Stub: immediately marks as initialized and attached.
  Future<void> initialize(String statePath) async {
    if (_isInitialized) return;

    // Real implementation:
    // final config = await getDefaultVeilidConfig(...);
    // final updateStream = await Veilid.instance.startupVeilidCore(config);
    // _updateSubscription = updateStream.listen(_handleUpdate, ...);
    // await Veilid.instance.attach();
    // _routingContext = await Veilid.instance.safeRoutingContext(
    //   sequencing: Sequencing.preferOrdered,
    // );

    _isInitialized = true;
    _isAttached = true;
    debugPrint('[VeilidService] Stub initialized (no Veilid backend)');
    notifyListeners();
  }

  /// Shut down the Veilid node and release resources.
  Future<void> shutdown() async {
    if (!_isInitialized) return;

    // Real implementation:
    // _routingContext?.close();
    // await _updateSubscription?.cancel();
    // await Veilid.instance.shutdownVeilidCore();

    _isAttached = false;
    _isInitialized = false;
    notifyListeners();
  }

  /// Wait until the node is attached to the network (or timeout).
  ///
  /// Stub: returns true immediately since we're always "attached".
  Future<bool> waitForAttach({Duration timeout = const Duration(seconds: 30)}) async {
    return true;
  }

  @override
  void dispose() {
    shutdown();
    super.dispose();
  }
}
