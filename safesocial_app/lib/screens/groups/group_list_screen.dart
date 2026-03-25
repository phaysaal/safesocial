import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/group_service.dart';

/// Displays all groups the user belongs to.
class GroupListScreen extends StatelessWidget {
  const GroupListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final groupService = context.watch<GroupService>();
    final groups = groupService.groups;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
      ),
      body: groups.isEmpty
          ? _buildEmptyState(theme)
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: groups.length,
              separatorBuilder: (_, __) => Divider(
                indent: 72,
                height: 1,
                color: theme.dividerTheme.color,
              ),
              itemBuilder: (context, index) {
                final group = groups[index];
                final messages = groupService.getGroupMessages(group.dhtKey);
                final lastMessage =
                    messages.isNotEmpty ? messages.last : null;
                final initial = group.name.isNotEmpty
                    ? group.name[0].toUpperCase()
                    : '?';

                return ListTile(
                  leading: CircleAvatar(
                    radius: 24,
                    backgroundColor: colorScheme.secondary,
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  title: Text(
                    group.name,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: lastMessage != null
                      ? Text(
                          lastMessage.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        )
                      : Text(
                          '${group.members.length} member${group.members.length == 1 ? '' : 's'}',
                          style: theme.textTheme.bodySmall,
                        ),
                  trailing: lastMessage != null
                      ? Text(
                          _formatTime(lastMessage.timestamp),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                          ),
                        )
                      : null,
                  onTap: () => context.push('/group/${group.dhtKey}'),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/groups/create'),
        tooltip: 'Create group',
        child: const Icon(Icons.group_add_outlined),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.group_outlined,
              size: 64,
              color: theme.colorScheme.primary.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No groups yet',
              style: theme.textTheme.headlineMedium?.copyWith(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Create one to start chatting with multiple people.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.month}/${time.day}';
  }
}
