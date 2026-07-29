import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/search_service.dart';
import '../../services/sphere_service.dart';

/// Search / discover contacts screen.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final results = SearchService.search(
      query: _query,
      contacts: context.watch<ContactService>().contacts,
      spheres: context.watch<SphereService>().spheres,
      posts: context.watch<FeedService>().posts,
      conversations: context.watch<ChatService>().conversations,
      myIdentityKey: context.watch<IdentityService>().publicKey,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Search',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 24,
          ),
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search messages, posts, spheres, people',
                prefixIcon: Icon(Icons.search, color: cs.onSurfaceVariant),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),

          // Quick actions
          if (_query.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  _QuickAction(
                    icon: Icons.person_add_outlined,
                    label: 'Add a new contact',
                    onTap: () => context.push('/contacts/add'),
                  ),
                  _QuickAction(
                    icon: Icons.group_add_outlined,
                    label: 'Create a group',
                    onTap: () => context.push('/spheres/create'),
                  ),
                  _QuickAction(
                    icon: Icons.qr_code_scanner,
                    label: 'Scan QR code',
                    onTap: () => context.push('/contacts/add'),
                  ),
                  const Divider(height: 24),
                ],
              ),
            ),

          // Results
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _query.isNotEmpty
                              ? Icons.search_off
                              : Icons.search,
                          size: 48,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _query.isNotEmpty
                              ? 'Nothing matched "$_query"'
                              : 'Search your messages, posts and spheres',
                          style: TextStyle(color: cs.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                        if (_query.isEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Searching happens on this device only.',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final result = results[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cs.surfaceContainerHighest,
                          child: Icon(_iconFor(result.kind),
                              size: 20, color: cs.onSurfaceVariant),
                        ),
                        title: Text(result.title),
                        subtitle: Text(
                          result.snippet,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          _labelFor(result.kind),
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        onTap: () => context.push(result.route),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(SearchResultKind kind) => switch (kind) {
        SearchResultKind.contact => Icons.person_outline,
        SearchResultKind.sphere => Icons.blur_on,
        SearchResultKind.post => Icons.article_outlined,
        SearchResultKind.message => Icons.chat_bubble_outline,
      };

  static String _labelFor(SearchResultKind kind) => switch (kind) {
        SearchResultKind.contact => 'Contact',
        SearchResultKind.sphere => 'Sphere',
        SearchResultKind.post => 'Post',
        SearchResultKind.message => 'Message',
      };
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: cs.onSurface, size: 20),
      ),
      title: Text(label),
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
    );
  }
}
