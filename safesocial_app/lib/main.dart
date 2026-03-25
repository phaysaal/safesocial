import 'package:flutter/material.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Real implementation initializes Veilid platform:
  // Veilid.instance.initializeVeilidCore({});

  final themeService = ThemeService();
  final veilidService = VeilidService();
  final identityService = IdentityService(veilidService: veilidService);
  final chatService = ChatService();
  final feedService = FeedService();
  final contactService = ContactService();
  final mediaService = MediaService();
  final groupService = GroupService();

  // Load theme first (doesn't need Veilid)
  await themeService.load();

  // Real implementation wires ChatService to VeilidService for incoming
  // message dispatch and starts the Veilid node in the background:
  // chatService.attachVeilidService(veilidService);
  // veilidService.onValueChange = (key, subkeys) {
  //   chatService.handleValueChange(key, subkeys);
  // };
  // final appDir = await getApplicationDocumentsDirectory();
  // final statePath = '${appDir.path}/veilid';
  // veilidService.initialize(statePath).then((_) async {
  //   await identityService.loadIdentity();
  //   await chatService.loadConversations();
  // }).catchError((e) {
  //   debugPrint('[main] Veilid initialization failed: $e');
  // });

  // Load local data (SharedPreferences-backed, no Veilid needed)
  await identityService.loadIdentity();
  await contactService.loadContacts();
  await groupService.loadGroups();
  await feedService.loadPosts();

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
      child: const SafeSocialApp(),
    ),
  );
}
