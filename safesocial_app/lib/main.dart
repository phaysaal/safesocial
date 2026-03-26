import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:veilid/veilid.dart';

import 'app.dart';
import 'services/veilid_service.dart';
import 'services/identity_service.dart';
import 'services/chat_service.dart';
import 'services/feed_service.dart';
import 'services/contact_service.dart';
import 'services/media_service.dart';
import 'services/group_service.dart';
import 'services/theme_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Veilid platform
  Veilid.instance.initializeVeilidCore({});

  final themeService = ThemeService();
  final veilidService = VeilidService();
  final identityService = IdentityService(veilidService: veilidService);
  final chatService = ChatService();
  final feedService = FeedService();
  final contactService = ContactService();
  final mediaService = MediaService();
  final groupService = GroupService();

  // Load theme first (no Veilid needed)
  await themeService.load();

  // Wire ChatService to VeilidService for incoming message dispatch
  chatService.attachVeilidService(veilidService);
  veilidService.onValueChange = (key, subkeys) {
    chatService.handleValueChange(key, subkeys);
  };

  // Load local data (SharedPreferences — available immediately)
  await contactService.loadContacts();
  await groupService.loadGroups();
  await feedService.loadPosts();

  // Start Veilid node in the background (non-blocking)
  final appDir = await getApplicationDocumentsDirectory();
  final statePath = '${appDir.path}/veilid';

  veilidService.initialize(statePath).then((_) async {
    // Once Veilid is ready, load identity and conversations from TableStore
    await identityService.loadIdentity();
    await chatService.loadConversations();
  }).catchError((e) {
    debugPrint('[main] Veilid initialization failed: $e');
    // Still try to load identity from SharedPreferences fallback
    identityService.loadIdentity();
  });

  // Also try loading identity from SharedPreferences immediately
  // (so the app doesn't show onboarding if user already exists)
  await identityService.loadIdentity();

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
      ],
      child: const SpheresApp(),
    ),
  );
}
