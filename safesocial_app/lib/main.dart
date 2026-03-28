import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/veilid_service.dart';
import 'services/identity_service.dart';
import 'services/chat_service.dart';
import 'services/feed_service.dart';
import 'services/contact_service.dart';
import 'services/media_service.dart';
import 'services/group_service.dart';
import 'services/theme_service.dart';
import 'services/call_service.dart';
import 'services/debug_log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themeService = ThemeService();
  final veilidService = VeilidService();
  final identityService = IdentityService(veilidService: veilidService);
  final chatService = ChatService();
  final feedService = FeedService();
  final contactService = ContactService();
  final mediaService = MediaService();
  final groupService = GroupService();
  final callService = CallService();

  // Load theme (no Veilid needed)
  await themeService.load();

  // Wire ChatService ↔ VeilidService
  chatService.attachVeilidService(veilidService);
  veilidService.onValueChange = (key, subkeys) {
    chatService.handleValueChange(key, subkeys);
  };

  // Load local data (SharedPreferences — always available)
  await identityService.loadIdentity();
  await contactService.loadContacts();
  await groupService.loadGroups();
  await feedService.loadPosts();

  // Set up relay for existing contacts — works WITHOUT Veilid
  _connectRelay(identityService, chatService, feedService, groupService, contactService, callService);

  // Start Veilid in the background AFTER the app is running
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final statePath = '${appDir.path}/veilid';

      // Ensure Veilid state directories exist
      await Directory(statePath).create(recursive: true);
      await Directory('$statePath/protected_store').create(recursive: true);
      await Directory('$statePath/table_store').create(recursive: true);
      await Directory('$statePath/block_store').create(recursive: true);

      await veilidService.initialize(statePath);
      await identityService.loadIdentity();
      await chatService.loadConversations();

      // Reconnect relay with any new identity from Veilid
      _connectRelay(identityService, chatService, feedService, groupService, contactService, callService);
    } catch (e) {
      DebugLogService().error('Main', 'Veilid startup failed (relay-only mode): $e');
      // Relay still works — Veilid is optional for messaging
    }
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeService),
        ChangeNotifierProvider.value(value: veilidService),
        ChangeNotifierProvider.value(value: identityService),
        ChangeNotifierProvider.value(value: chatService),
        ChangeNotifierProvider.value(value: feedService),
        ChangeNotifierProvider.value(value: contactService),
        ChangeNotifierProvider.value(value: mediaService),
        ChangeNotifierProvider.value(value: groupService),
        ChangeNotifierProvider.value(value: callService),
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

  DebugLogService().success('Main', 'Relay connected for ${contactService.contacts.length} contacts');
}
