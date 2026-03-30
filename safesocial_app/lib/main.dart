import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/identity_service.dart';
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

  // Set my info for contact handshakes and chat
  if (identityService.isOnboarded) {
    contactService.setMyInfo(identityService.publicKey!, identityService.currentIdentity!.displayName);
    chatService.setMyInfo(identityService.publicKey!, identityService.secretKey!);
    callService.setMyInfo(identityService.publicKey!, identityService.secretKey!);
  }

  // Set up relay for existing contacts
  _connectRelay(identityService, chatService, feedService, groupService, contactService, callService, albumService);

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
        ChangeNotifierProvider.value(value: DebugLogService()),
      ],
      child: const SpheresApp(),
    ),
  );
}

/// Connect relay for all existing contacts.
void _connectRelay(
  IdentityService identityService,
  ChatService chatService,
  FeedService feedService,
  GroupService groupService,
  ContactService contactService,
  CallService callService,
  AlbumService albumService,
) {
  if (!identityService.isOnboarded) return;

  final pubKey = identityService.publicKey!;
  final secretKey = identityService.secretKey!;

  for (final contact in contactService.contacts) {
    if (contact.blocked) continue;
    chatService.connectRelay(contact.publicKey);
  }
  
  // Feed, Group, and Album services would be updated to use Relay too
  feedService.initSync(pubKey, secretKey, contactService.contacts);
  groupService.initSync(pubKey, secretKey);
  albumService.initSync(pubKey, secretKey);

  DebugLogService().success('Main', 'Relay connected for ${contactService.contacts.length} contacts');
}
