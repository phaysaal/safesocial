import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'services/identity_service.dart';
import 'services/theme_service.dart';
import 'theme/app_theme.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/chat/chat_list_screen.dart';
import 'screens/chat/chat_detail_screen.dart';
import 'screens/feed/feed_screen.dart';
import 'screens/contacts/contact_list_screen.dart';
import 'screens/contacts/add_contact_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/profile/edit_profile_screen.dart';
import 'screens/media/media_viewer_screen.dart';
import 'screens/groups/group_list_screen.dart';
import 'screens/groups/create_group_screen.dart';
import 'screens/groups/group_detail_screen.dart';
import 'screens/groups/group_settings_screen.dart';
import 'screens/groups/add_group_member_screen.dart';
import 'screens/notifications/notifications_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/search/search_screen.dart';
import 'screens/feed/post_detail_screen.dart';

/// Root application widget for Spheres.
class SpheresApp extends StatelessWidget {
  const SpheresApp({super.key});

  @override
  Widget build(BuildContext context) {
    final identityService = context.watch<IdentityService>();
    final themeService = context.watch<ThemeService>();

    final router = GoRouter(
      initialLocation: identityService.isOnboarded ? '/' : '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          builder: (context, state) => const OnboardingScreen(),
        ),
        ShellRoute(
          builder: (context, state, child) => HomeScreen(child: child),
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const FeedScreen(),
            ),
            GoRoute(
              path: '/chats',
              builder: (context, state) => const ChatListScreen(),
            ),
            GoRoute(
              path: '/contacts',
              builder: (context, state) => const ContactListScreen(),
            ),
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
        GoRoute(
          path: '/chat/:id',
          builder: (context, state) => ChatDetailScreen(
            conversationId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/contacts/add',
          builder: (context, state) => const AddContactScreen(),
        ),
        GoRoute(
          path: '/profile/edit',
          builder: (context, state) => const EditProfileScreen(),
        ),
        GoRoute(
          path: '/media/view',
          builder: (context, state) => MediaViewerScreen(
            mediaRef: state.uri.queryParameters['ref'],
          ),
        ),
        GoRoute(
          path: '/groups',
          builder: (context, state) => const GroupListScreen(),
        ),
        GoRoute(
          path: '/groups/create',
          builder: (context, state) => const CreateGroupScreen(),
        ),
        GoRoute(
          path: '/group/:dhtKey',
          builder: (context, state) => GroupDetailScreen(
            dhtKey: state.pathParameters['dhtKey']!,
          ),
        ),
        GoRoute(
          path: '/group/:dhtKey/settings',
          builder: (context, state) => GroupSettingsScreen(
            dhtKey: state.pathParameters['dhtKey']!,
          ),
        ),
        GoRoute(
          path: '/group/:dhtKey/add-members',
          builder: (context, state) => AddGroupMemberScreen(
            dhtKey: state.pathParameters['dhtKey']!,
          ),
        ),
        GoRoute(
          path: '/notifications',
          builder: (context, state) => const NotificationsScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: '/search',
          builder: (context, state) => const SearchScreen(),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) => PostDetailScreen(
            postId: state.pathParameters['id']!,
          ),
        ),
      ],
    );

    return MaterialApp.router(
      title: 'Spheres',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeService.themeMode,
      routerConfig: router,
    );
  }
}

/// Home screen with bottom navigation bar and four tabs.
class HomeScreen extends StatefulWidget {
  final Widget child;

  const HomeScreen({super.key, required this.child});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  static const _routes = ['/', '/chats', '/contacts', '/profile'];

  void _onTabTapped(int index) {
    if (index != _currentIndex) {
      setState(() => _currentIndex = index);
      context.go(_routes[index]);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the index in sync when navigating via GoRouter directly.
    final location = GoRouterState.of(context).uri.toString();
    for (int i = 0; i < _routes.length; i++) {
      if (location == _routes[i]) {
        if (_currentIndex != i) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _currentIndex = i);
          });
        }
        break;
      }
    }

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabTapped,
        backgroundColor: Theme.of(context).colorScheme.surface,
        indicatorColor:
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Contacts',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
