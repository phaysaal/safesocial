import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

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
    final contactService = context.watch<ContactService>();
    final contacts = contactService.contacts;

    final filtered = _query.isEmpty
        ? contacts
        : contacts.where((c) {
            final q = _query.toLowerCase();
            return c.displayName.toLowerCase().contains(q) ||
                c.publicKey.toLowerCase().contains(q);
          }).toList();

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
                hintText: 'Search contacts...',
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
                    onTap: () => context.push('/groups/create'),
                  ),
                  _QuickAction(
                    icon: Icons.qr_code_scanner,
                    label: 'Scan QR code',
                    onTap: () {},
                  ),
                  const Divider(height: 24),
                ],
              ),
            ),

          // Results
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _query.isNotEmpty
                              ? Icons.search_off
                              : Icons.people_outline,
                          size: 48,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _query.isNotEmpty
                              ? 'No contacts match "$_query"'
                              : 'No contacts yet',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final c = filtered[index];
                      return ListTile(
                        leading: UserAvatar(
                          displayName: c.displayName,
                          size: AvatarSize.medium,
                        ),
                        title: Text(
                          c.displayName,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          _truncateKey(c.publicKey),
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: c.blocked
                            ? Icon(Icons.block, color: cs.error, size: 18)
                            : null,
                        onTap: () => context.push('/chat/${c.publicKey}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _truncateKey(String key) {
    if (key.length <= 16) return key;
    return '${key.substring(0, 8)}...${key.substring(key.length - 6)}';
  }
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
