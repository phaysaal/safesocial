import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'app_services.dart';
import 'background_sync.dart';

/// Two ways in.
///
/// The user opening the app: load everything, show the UI. A push wake on
/// Android: the UnifiedPush plugin starts this entry point with
/// `--unifiedpush-bg`, and there is no screen to show — load everything, let
/// the mailboxes drain into notifications, and exit when the wake window ends.
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final services = await AppServices.boot();

  final woken = args.contains('--unifiedpush-bg');
  if (woken) {
    await services.startNotifications(onWake: BackgroundSync.run);
    await BackgroundSync.run();
    return;
  }

  // Notifications and the wake provider start after the first frame so they
  // never delay the UI; a failure in either is logged, not fatal.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    services.startNotifications(onWake: BackgroundSync.run);
  });

  runApp(
    MultiProvider(
      providers: services.providers(),
      child: const SpheresApp(),
    ),
  );
}
