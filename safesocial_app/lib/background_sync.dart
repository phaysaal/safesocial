import 'dart:async';

import 'app_services.dart';
import 'services/debug_log_service.dart';
import 'services/relay_service.dart';

/// What happens when the device is woken for mail and there is no UI.
///
/// The wake carried nothing. Bring the services up, let the hub subscribe to
/// every mailbox and drain what is waiting, give the inbound events a moment
/// to turn into notifications, and stop. Everything that arrives is verified,
/// decrypted and stored exactly as it would be in the foreground, by the same
/// code.
class BackgroundSync {
  BackgroundSync._();

  static bool _running = false;

  /// True in the `--unifiedpush-bg` process, where there is no UI to keep the
  /// socket for: when the window closes the hub rests until the next wake.
  static bool headless = false;

  /// How long to keep the process alive after the hub is up, so slow mailboxes
  /// still drain. Android allows a wake a short budget; this is well inside it.
  static Duration hold = const Duration(seconds: 12);

  static Future<void> run() async {
    if (_running) return;
    _running = true;
    final log = DebugLogService();
    try {
      log.info('Wake', 'Woken for mail; syncing');
      final services = await AppServices.boot();
      // Notifications must be listening before anything arrives.
      await services.startNotifications(onWake: () => unawaited(run()));
      // If the hub is already up, make sure quiet mailboxes are checked; if
      // it is not, this starts it.
      await RelayService.verifyAll();
      await Future<void>.delayed(hold);
      if (headless) {
        // Android cuts this process's network a few seconds after the push;
        // a socket left up would only churn through failed reconnects.
        RelayHub.instance.rest();
        log.info('Wake', 'Sync window closed; socket released until the next wake');
      } else {
        log.info('Wake', 'Sync window closed');
      }
    } catch (e) {
      log.error('Wake', 'Background sync failed: $e');
    } finally {
      _running = false;
    }
  }
}
