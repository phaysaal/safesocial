import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
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

  // Load theme (no Veilid needed)
  await themeService.load();

  // Wire services
  syncService.attachServices(identityService);
  

  // Load local data (SharedPreferences — always available)
  await identityService.loadIdentity();
  await contactService.loadContacts();
  await groupService.loadGroups();
  await feedService.loadPosts();
  await ringService.loadRings();
  await albumService.loadAlbums();

  // Set my info for contact handshakes
  if (identityService.publicKey != null) {
    contactService.setMyInfo(identityService.publicKey!, identityService.currentIdentity?.displayName ?? 'User');
  }

  // Set up relay for existing contacts — works WITHOUT Veilid
  _connectRelay(identityService, chatService, feedService, groupService, contactService, callService, albumService);

  // Start Veilid and Rust Core in the background AFTER the app is running
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      
      // Initialize Rust Core (Double Ratchet brain)
      await rustCoreService.init();


      _connectRelay(identityService, chatService, feedService, groupService, contactService, callService, albumService);
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
        ChangeNotifierProvider.value(value: DebugLogService()),
      ],
      child: const SpheresApp(),
    ),
  );
}

/// Connect relay for all existing contacts. Works without Veilid.
void _connectRelay(
  IdentityService identityService,
  ChatService chatService,
  FeedService feedService,
  GroupService groupService,
  ContactService contactService,
  CallService callService,
  AlbumService albumService,
) {
  final pubKey = identityService.publicKey;
  if (pubKey == null || pubKey.isEmpty) return;

  chatService.setMyPublicKey(pubKey);
  callService.setMyPublicKey(pubKey);
  for (final contact in contactService.contacts) {
    chatService.connectRelay(contact.publicKey);
    callService.connectSignaling(contact.publicKey);
  }
  feedService.initSync(pubKey, contactService.contacts);
  groupService.initSync(pubKey);
  albumService.initSync(pubKey);

  DebugLogService().success('Main', 'Relay connected for ${contactService.contacts.length} contacts');
}
