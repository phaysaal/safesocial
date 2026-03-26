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

  // Set up relay for existing contacts (chat + feed sync)
  if (identityService.publicKey != null) {
    chatService.setMyPublicKey(identityService.publicKey!);
    for (final contact in contactService.contacts) {
      chatService.connectRelay(contact.publicKey);
    }
    feedService.initSync(identityService.publicKey!, contactService.contacts);
    groupService.initSync(identityService.publicKey!);
  }

  // Start Veilid in the background AFTER the app is running
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final statePath = '${appDir.path}/veilid';
      await veilidService.initialize(statePath);
      await identityService.loadIdentity();
      await chatService.loadConversations();

      // Connect relay for any contacts loaded from Veilid
      if (identityService.publicKey != null) {
        chatService.setMyPublicKey(identityService.publicKey!);
        for (final contact in contactService.contacts) {
          chatService.connectRelay(contact.publicKey);
        }
        feedService.initSync(identityService.publicKey!, contactService.contacts);
        groupService.initSync(identityService.publicKey!);
      }
    } catch (e) {
      debugPrint('[main] Veilid startup failed (local mode): $e');
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
        ChangeNotifierProvider.value(value: DebugLogService()),
      ],
      child: const SpheresApp(),
    ),
  );
}
