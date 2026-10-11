import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'app_wiring.dart';
import 'crypto/session_manager.dart';
import 'services/album_service.dart';
import 'services/app_lock_service.dart';
import 'services/call_config.dart';
import 'services/call_service.dart';
import 'services/chat_service.dart';
import 'services/contact_service.dart';
import 'services/debug_log_service.dart';
import 'services/feed_service.dart';
import 'services/identity_service.dart';
import 'services/library_service.dart';
import 'services/media_service.dart';
import 'services/notification_service.dart';
import 'services/outbox_service.dart';
import 'services/relay_config.dart';
import 'services/relay_service.dart';
import 'services/secure_store.dart';
import 'services/sphere_chat_service.dart';
import 'services/sphere_service.dart';
import 'services/sphere_sync_service.dart';
import 'services/sync_service.dart';
import 'services/theme_service.dart';
import 'services/wake_service.dart';

/// Every service the app runs on, built and loaded in one place.
///
/// There are two ways into this process: the user opening the app, and a push
/// wake with no UI at all. Both need the same services loaded in the same
/// order — identity before anything that encrypts, relay config before the
/// first request, spheres before sphere chats — so the order lives here once.
class AppServices {
  final themeService = ThemeService();
  final identityService = IdentityService();
  final chatService = ChatService();
  final feedService = FeedService();
  final contactService = ContactService();
  final mediaService = MediaService();
  final callService = CallService();
  final syncService = SyncService();
  final albumService = AlbumService();
  final relayService = RelayService();
  final sessionManager = SessionManager();
  final outboxService = OutboxService();
  // A second queue: sphere content goes out on the feed channel, so it needs
  // its own sender and its own storage, but the same durability.
  final feedOutboxService = FeedOutboxService();
  final sphereService = SphereService();
  final relayConfig = RelayConfig();
  final libraryService = LibraryService();
  late final sphereChatService = SphereChatService(sphereService);
  late final sphereSyncService = SphereSyncService(sphereService);
  final callConfig = CallConfig();
  final notificationService = NotificationService();
  final appLockService = AppLockService();
  late final wakeService = WakeService(provider: defaultWakeProvider());

  /// The one instance for this process, once [boot] has run.
  static AppServices? current;

  bool _loaded = false;

  /// Build and load everything. Idempotent per process.
  static Future<AppServices> boot() async {
    final existing = current;
    if (existing != null) {
      await existing.load();
      return existing;
    }
    final services = AppServices();
    current = services;
    await services.load();
    return services;
  }

  /// Load local state and connect the identity to every service.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    // Before anything touches storage: without the key loaded, early reads
    // miss encrypted values and would rewrite them in the clear.
    await SecureStore.instance.init();

    await themeService.load();
    // Must precede any relay traffic, or the first requests go to the default
    // host.
    await relayConfig.load();
    await callConfig.load();
    await libraryService.load();
    await notificationService.load();
    await wakeService.load();

    syncService.attachServices(identityService);
    // A device that has just been linked holds a whole new identity on disk;
    // every service reloads around it rather than asking for a restart.
    syncService.onIdentityReceived = reload;

    await identityService.loadIdentity();
    await contactService.loadContacts();
    await feedService.loadPosts();
    await albumService.loadAlbums();
    await chatService.loadConversations();

    // Connect the identity to every service that needs it. Onboarding calls
    // the same function, so a freshly created identity works without a
    // restart.
    await wire();
  }

  /// Re-read local state and re-wire after the identity on disk changed
  /// underneath us (a restore, or a device link).
  Future<void> reload() async {
    await identityService.loadIdentity();
    await contactService.loadContacts();
    await feedService.loadPosts();
    await albumService.loadAlbums();
    await chatService.loadConversations();
    await wire();
  }

  Future<void> wire() => wireIdentity(
        identityService: identityService,
        sessionManager: sessionManager,
        contactService: contactService,
        chatService: chatService,
        outboxService: outboxService,
        callService: callService,
        feedService: feedService,
        albumService: albumService,
        sphereService: sphereService,
        libraryService: libraryService,
        sphereChatService: sphereChatService,
        sphereSyncService: sphereSyncService,
        feedOutboxService: feedOutboxService,
        relayService: relayService,
      );

  /// Start listening for inbound events and arrange to be woken for them.
  ///
  /// Separate from [load] because a wake with no UI still wants both, while
  /// tests want neither.
  Future<void> startNotifications({required void Function() onWake}) async {
    try {
      await notificationService.start();
    } catch (e) {
      DebugLogService().error('Notify', 'Notifications unavailable: $e');
    }
    wakeService.onWake = onWake;
    try {
      await wakeService.start();
    } catch (e) {
      DebugLogService().error('Wake', 'Wake provider failed to start: $e');
    }
  }

  /// Providers for the widget tree.
  List<SingleChildWidget> providers() => [
        ChangeNotifierProvider.value(value: themeService),
        ChangeNotifierProvider.value(value: identityService),
        ChangeNotifierProvider.value(value: chatService),
        ChangeNotifierProvider.value(value: feedService),
        ChangeNotifierProvider.value(value: contactService),
        ChangeNotifierProvider.value(value: mediaService),
        ChangeNotifierProvider.value(value: callService),
        ChangeNotifierProvider.value(value: syncService),
        ChangeNotifierProvider.value(value: albumService),
        ChangeNotifierProvider.value(value: relayService),
        Provider<SessionManager>.value(value: sessionManager),
        ChangeNotifierProvider.value(value: outboxService),
        ChangeNotifierProvider.value(value: sphereService),
        ChangeNotifierProvider.value(value: libraryService),
        ChangeNotifierProvider.value(value: sphereChatService),
        ChangeNotifierProvider.value(value: sphereSyncService),
        ChangeNotifierProvider.value(value: feedOutboxService),
        ChangeNotifierProvider.value(value: relayConfig),
        ChangeNotifierProvider.value(value: callConfig),
        ChangeNotifierProvider.value(value: notificationService),
        ChangeNotifierProvider.value(value: wakeService),
        ChangeNotifierProvider.value(value: appLockService),
        ChangeNotifierProvider.value(value: DebugLogService()),
      ];

  @visibleForTesting
  static void reset() => current = null;
}
