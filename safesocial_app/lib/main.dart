import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'app_wiring.dart';
import 'crypto/session_manager.dart';
import 'services/identity_service.dart';
import 'services/sphere_service.dart';
import 'services/outbox_service.dart';
import 'services/chat_service.dart';
import 'services/feed_service.dart';
import 'services/contact_service.dart';
import 'services/media_service.dart';
import 'services/group_service.dart';
import 'services/theme_service.dart';
import 'services/call_service.dart';
import 'services/debug_log_service.dart';
import 'services/rust_core_service.dart';
import 'services/sync_service.dart';
import 'services/ring_service.dart';
import 'services/album_service.dart';
import 'services/relay_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeService = ThemeService();
  final identityService = IdentityService();
  final chatService = ChatService();
  final feedService = FeedService();
  final contactService = ContactService();
  final mediaService = MediaService();
  final groupService = GroupService();
  final callService = CallService();
  final rustCoreService = RustCoreService();
  final syncService = SyncService();
  final ringService = RingService();
  final albumService = AlbumService();
  final relayService = RelayService();

  // Load theme
  await themeService.load();

  final sessionManager = SessionManager();
  final outboxService = OutboxService();
  final sphereService = SphereService();

  // Wire services
  syncService.attachServices(identityService);

  // Load local data (Secure + SharedPrefs)
  await identityService.loadIdentity();
  await contactService.loadContacts();
  await groupService.loadGroups();
  await feedService.loadPosts();
  await ringService.loadRings();
  await albumService.loadAlbums();
  await chatService.loadConversations();

  // Connect the identity to every service that needs it. Onboarding calls the
  // same function, so a freshly created identity works without a restart.
  await wireIdentity(
    identityService: identityService,
    sessionManager: sessionManager,
    contactService: contactService,
    chatService: chatService,
    outboxService: outboxService,
    callService: callService,
    feedService: feedService,
    groupService: groupService,
    albumService: albumService,
    sphereService: sphereService,
  );

  // Start Rust Core in the background (non-blocking)
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await rustCoreService.init();
    } catch (e) {
      DebugLogService().error('Main', 'Backend startup failed: $e');
    }
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeService),
        ChangeNotifierProvider.value(value: identityService),
        ChangeNotifierProvider.value(value: chatService),
        ChangeNotifierProvider.value(value: feedService),
        ChangeNotifierProvider.value(value: contactService),
        ChangeNotifierProvider.value(value: mediaService),
        ChangeNotifierProvider.value(value: groupService),
        ChangeNotifierProvider.value(value: callService),
        ChangeNotifierProvider.value(value: rustCoreService),
        ChangeNotifierProvider.value(value: syncService),
        ChangeNotifierProvider.value(value: ringService),
        ChangeNotifierProvider.value(value: albumService),
        ChangeNotifierProvider.value(value: relayService),
        Provider<SessionManager>.value(value: sessionManager),
        ChangeNotifierProvider.value(value: outboxService),
        ChangeNotifierProvider.value(value: sphereService),
        ChangeNotifierProvider.value(value: DebugLogService()),
      ],
      child: const SpheresApp(),
    ),
  );
}
