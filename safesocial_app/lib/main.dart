import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'app_services.dart';
import 'background_sync.dart';

/// Three ways in.
///
/// The user opening the app: load everything, show the UI. A push wake on
/// Android: the UnifiedPush plugin starts this entry point with
/// `--unifiedpush-bg`, and there is no screen to show — load everything, let
/// the mailboxes drain into notifications, and exit when the wake window ends.
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // What is bundled and under what terms: the heading face and the
  // dictionary behind call notes. Shown under About, "View licenses".
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
        const ['Outfit'], await rootBundle.loadString('assets/fonts/OFL.txt'));
    yield LicenseEntryWithLineBreaks(
        const ['AutoEar v2 engine (WordNet-derived dictionary)'],
        await rootBundle.loadString('assets/licenses/NOTICE-wordnet.txt'));
  });

  final services = await AppServices.boot();

  final woken = args.contains('--unifiedpush-bg');
  if (woken) {
    BackgroundSync.headless = true;
    await services.startNotifications(onWake: BackgroundSync.run);
    await BackgroundSync.run();
    return;
  }
  // An alarm for a scheduled message or post, with the app closed: the same
  // headless path, plus the sweeps that send what is due.
  if (args.contains('--scheduled-bg')) {
    BackgroundSync.headless = true;
    await services.startNotifications(onWake: BackgroundSync.run);
    await BackgroundSync.runScheduled(services);
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
