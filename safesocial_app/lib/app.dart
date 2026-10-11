import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:app_links/app_links.dart';

import 'services/identity_service.dart';
import 'services/notification_service.dart';
import 'services/app_lock_service.dart';
import 'services/library_service.dart';
import 'services/relay_service.dart';
import 'services/theme_service.dart';
import 'services/call_service.dart';
import 'widgets/responsive_layout.dart';
import 'theme/app_theme.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/chat/chat_list_screen.dart';
import 'screens/chat/chat_detail_screen.dart';
import 'screens/chat/starred_screen.dart';
import 'screens/call/call_history_screen.dart';
import 'screens/feed/drafts_screen.dart';
import 'services/contact_service.dart';
import 'screens/feed/feed_screen.dart';
import 'screens/feed/memories_screen.dart';
import 'screens/feed/saved_screen.dart';
import 'screens/contacts/contact_list_screen.dart';
import 'screens/contacts/add_contact_screen.dart';
import 'screens/media/album_list_screen.dart';
import 'screens/media/album_detail_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/profile/edit_profile_screen.dart';
import 'screens/media/media_viewer_screen.dart';
import 'screens/spheres/sphere_list_screen.dart';
import 'screens/spheres/create_sphere_screen.dart';
import 'screens/spheres/sphere_detail_screen.dart';
import 'screens/spheres/sphere_chat_screen.dart';
import 'screens/spheres/sphere_media_screen.dart';
import 'screens/contacts/verify_contact_screen.dart';
import 'screens/spheres/sphere_log_screen.dart';
import 'screens/notifications/notifications_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/settings/social_recovery_screen.dart';
import 'screens/settings/debug_console_screen.dart';
import 'screens/search/search_screen.dart';
import 'screens/feed/post_detail_screen.dart';
import 'screens/call/call_screen.dart';

/// Root application widget for Spheres.
class SpheresApp extends StatefulWidget {
  const SpheresApp({super.key});

  @override
  State<SpheresApp> createState() => _SpheresAppState();
}

class _SpheresAppState extends State<SpheresApp> with WidgetsBindingObserver {
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeepLinking();
    _initRouter();
    AppLifecycle.foreground = true;
    // A tapped notification opens the thing it was about.
    context.read<NotificationService>().onOpen = (route) {
      if (mounted) _router.push(route);
    };
    // An identity that was created before the permission question existed
    // is asked once, after the first frame, so the dialog has a window.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (context.read<IdentityService>().isOnboarded) {
        context.read<NotificationService>().ensurePermissionAsked();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Notifications are suppressed while the UI is on screen; a wake with no
    // UI never gets here and stays "background".
    AppLifecycle.foreground = state == AppLifecycleState.resumed;
    // Leaving the screen with the app lock on means unlocking on return.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (context.read<LibraryService>().appLock) context.read<AppLockService>().lock();
    }
    if (state != AppLifecycleState.resumed) return;
    // Coming back is the moment a socket is most likely to have died without
    // saying so: the phone slept, the network changed, a NAT dropped an idle
    // mapping. Nothing closes the socket in any of those, so the app would
    // otherwise sit there looking connected and quietly receiving nothing.
    unawaited(RelayService.verifyAll());
  }

  void _initDeepLinking() {
    _appLinks = AppLinks();
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      debugPrint('[DeepLink] Received URI: $uri');
      _handleDeepLink(uri);
    });
  }

  void _handleDeepLink(Uri uri) {
    if (uri.scheme == 'spheres' && uri.host == 'add') {
      // Future: Navigate to add contact with pre-filled info
    }
    if (uri.scheme == 'spheres' && uri.host == 'join') {
      _handleJoinLink(uri);
    }
  }

  /// An invite link. Asking is all this does; an admin still approves.
  Future<void> _handleJoinLink(Uri uri) async {
    final sphereId = uri.queryParameters['s'];
    final token = uri.queryParameters['t'];
    final via = uri.queryParameters['via'];
    final name = uri.queryParameters['n'] ?? 'a sphere';
    if (sphereId == null || token == null || via == null) return;
    final ctx = _router.routerDelegate.navigatorKey.currentContext;
    if (ctx == null) return;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text('Ask to join $name?'),
        content: const Text(
            'Your name and key are sent to the admin who made this link. If they say yes, '
            'you become a member and a contact of theirs.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ask')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<ContactService>().sendJoinRequest(adminKey: via, sphereId: sphereId, token: token);
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Asked. The admin decides.')));
    } catch (e) {
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _initRouter() {
    // Fix Issue #8: Create router once
    _router = GoRouter(
      initialLocation: '/',
      redirect: (context, state) {
        final identity = context.read<IdentityService>();
        final onboarded = identity.isOnboarded;
        final goingToOnboarding = state.matchedLocation == '/onboarding';

        // Fix Issue #6: Route Guards
        if (!onboarded && !goingToOnboarding) return '/onboarding';
        if (onboarded && goingToOnboarding) return '/';
        
        return null;
      },
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
            GoRoute(
              path: '/console',
              builder: (context, state) => const DebugConsoleScreen(),
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
          path: '/call',
          builder: (context, state) => const CallScreen(),
        ),
        GoRoute(
          path: '/albums',
          builder: (context, state) => const AlbumListScreen(),
        ),
        GoRoute(
          path: '/album/:id',
          builder: (context, state) => AlbumDetailScreen(
            albumId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/saved',
          builder: (context, state) => const SavedScreen(),
        ),
        GoRoute(
          path: '/memories',
          builder: (context, state) => const MemoriesScreen(),
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
          path: '/spheres',
          builder: (context, state) => const SphereListScreen(),
        ),
        GoRoute(
          path: '/spheres/create',
          builder: (context, state) => const CreateSphereScreen(),
        ),
        GoRoute(
          path: '/sphere/:id',
          builder: (context, state) => SphereDetailScreen(
            sphereId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/drafts',
          builder: (context, state) => const DraftsScreen(),
        ),
        GoRoute(
          path: '/calls',
          builder: (context, state) => const CallHistoryScreen(),
        ),
        GoRoute(
          path: '/starred',
          builder: (context, state) => const StarredScreen(),
        ),
        GoRoute(
          path: '/sphere/:id/media',
          builder: (context, state) => SphereMediaScreen(
            sphereId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/contact/:id/verify',
          builder: (context, state) => VerifyContactScreen(
            contactKey: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/sphere/:id/chat',
          builder: (context, state) => SphereChatScreen(
            sphereId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/sphere/:id/log',
          builder: (context, state) => SphereLogScreen(
            sphereId: state.pathParameters['id']!,
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
          path: '/settings/recovery',
          builder: (context, state) => const SocialRecoveryScreen(),
        ),
        GoRoute(
          path: '/search',
          builder: (context, state) => const SearchScreen(),
        ),
        GoRoute(
          path: '/debug',
          builder: (context, state) => const DebugConsoleScreen(),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) => PostDetailScreen(
            postId: state.pathParameters['id']!,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeService = context.watch<ThemeService>();

    return MaterialApp.router(
      title: 'Spheres',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeService.themeMode,
      routerConfig: _router,
      builder: (context, child) => _LockGate(child: child ?? const SizedBox.shrink()),
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

  static const _routes = ['/', '/chats', '/contacts', '/profile', '/console'];

  @override
  void initState() {
    super.initState();
    // Listen for incoming calls
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final callService = context.read<CallService>();
      callService.addListener(_onCallStateChanged);
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _onCallStateChanged() {
    final callService = context.read<CallService>();
    if (callService.state == CallState.ringing && callService.isIncomingCall) {
      // Check if we are already on the call screen
      final location = GoRouterState.of(context).uri.toString();
      if (location != '/call') {
        context.push('/call');
      }
    }
  }

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

    final cs = Theme.of(context).colorScheme;
    final tablet = isTablet(context);

    final destinations = const [
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
      NavigationDestination(
        icon: Icon(Icons.terminal_outlined),
        selectedIcon: Icon(Icons.terminal),
        label: 'Console',
      ),
    ];

    // Tablet: side navigation rail
    if (tablet) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _currentIndex,
              onDestinationSelected: _onTabTapped,
              labelType: NavigationRailLabelType.all,
              backgroundColor: cs.surface,
              indicatorColor: cs.primary.withValues(alpha: 0.15),
              destinations: destinations.map((d) => NavigationRailDestination(
                icon: d.icon,
                selectedIcon: d.selectedIcon,
                label: Text(d.label),
              )).toList(),
            ),
            VerticalDivider(width: 1, color: cs.outline),
            Expanded(child: widget.child),
          ],
        ),
      );
    }

    // Phone: bottom navigation bar
    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabTapped,
        backgroundColor: cs.surface,
        indicatorColor: cs.primary.withValues(alpha: 0.15),
        destinations: destinations,
      ),
    );
  }
}

/// Covers the whole app while the lock is engaged. Nothing underneath is
/// hidden from the widget tree — this is a shutter, not encryption; the
/// encryption is at rest in SecureStore regardless.
class _LockGate extends StatelessWidget {
  final Widget child;
  const _LockGate({required this.child});

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLockService>();
    if (!lock.locked) return child;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 64, color: cs.primary),
            const SizedBox(height: 16),
            const Text('Spheres is locked'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: lock.unlock,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
  }
}
