import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/group.dart';
import '../../services/group_service.dart';
import '../../services/identity_service.dart';
import '../../widgets/avatar.dart';

/// Group management screen showing group info, members, and admin actions.
class GroupSettingsScreen extends StatefulWidget {
  final String dhtKey;

  const GroupSettingsScreen({super.key, required this.dhtKey});

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  Future<void> _editGroupName(
    BuildContext context,
    GroupService groupService,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Group Name'),
        content: TextField(
          controller: controller,
          maxLength: 50,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Group name',
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newName != null && newName.isNotEmpty && newName != currentName) {
      await groupService.updateGroup(widget.dhtKey, name: newName);
    }
  }

  Future<void> _editGroupDescription(
    BuildContext context,
    GroupService groupService,
    String currentDescription,
  ) async {
    final controller = TextEditingController(text: currentDescription);
    final newDesc = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Description'),
        content: TextField(
          controller: controller,
          maxLength: 200,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Group description',
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newDesc != null && newDesc != currentDescription) {
      await groupService.updateGroup(widget.dhtKey, description: newDesc);
    }
  }

  Future<void> _confirmLeaveGroup(
    BuildContext context,
    GroupService groupService,
    String publicKey,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Group'),
        content: const Text(
          'Are you sure you want to leave this group? You will no longer receive messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await groupService.leaveGroup(widget.dhtKey, publicKey);
      if (mounted) {
        context.go('/groups');
      }
    }
  }

  Future<void> _confirmDeleteGroup(
    BuildContext context,
    GroupService groupService,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Group'),
        content: const Text(
          'Are you sure you want to delete this group? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await groupService.deleteGroup(widget.dhtKey);
      if (mounted) {
        context.go('/groups');
      }
    }
  }

  Future<void> _confirmRemoveMember(
    BuildContext context,
    GroupService groupService,
    GroupMember member,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Member'),
        content: Text(
          'Remove ${member.displayName} from this group?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await groupService.removeMember(widget.dhtKey, member.publicKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final groupService = context.watch<GroupService>();
    final identityService = context.watch<IdentityService>();

    final group = groupService.getGroup(widget.dhtKey);
    final myPublicKey = identityService.publicKey ?? '';
    final amAdmin = groupService.isAdmin(widget.dhtKey, myPublicKey);

    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Group Settings')),
        body: const Center(child: Text('Group not found.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Group Settings'),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 24),

          // Group avatar
          Center(
            child: CircleAvatar(
              radius: 48,
              backgroundColor: colorScheme.secondary,
              child: Text(
                group.name.isNotEmpty ? group.name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 40,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Group name
          Center(
            child: InkWell(
              onTap: amAdmin
                  ? () => _editGroupName(context, groupService, group.name)
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        group.name,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (amAdmin) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.edit,
                        size: 18,
                        color: colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // Group description
          if (group.description.isNotEmpty || amAdmin)
            Center(
              child: InkWell(
                onTap: amAdmin
                    ? () => _editGroupDescription(
                          context,
                          groupService,
                          group.description,
                        )
                    : null,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    group.description.isNotEmpty
                        ? group.description
                        : 'Add a description',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withOpacity(
                        group.description.isNotEmpty ? 0.7 : 0.4,
                      ),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),

          const SizedBox(height: 24),
          const Divider(),

          // Members section header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text(
                  'Members (${group.members.length})',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
                const Spacer(),
                if (amAdmin)
                  TextButton.icon(
                    onPressed: () =>
                        context.push('/group/${widget.dhtKey}/add-members'),
                    icon: const Icon(Icons.person_add_outlined, size: 18),
                    label: const Text('Add'),
                  ),
              ],
            ),
          ),

          // Members list
          ...group.members.map(
            (member) => _buildMemberTile(
              context,
              theme,
              colorScheme,
              groupService,
              member,
              amAdmin,
              myPublicKey,
            ),
          ),

          const Divider(height: 32),

          // Leave group
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () =>
                  _confirmLeaveGroup(context, groupService, myPublicKey),
              icon: const Icon(Icons.exit_to_app, color: Colors.red),
              label: const Text(
                'Leave Group',
                style: TextStyle(color: Colors.red),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ),

          // Delete group (admin only)
          if (amAdmin) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ElevatedButton.icon(
                onPressed: () =>
                    _confirmDeleteGroup(context, groupService),
                icon: const Icon(Icons.delete_forever),
                label: const Text('Delete Group'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildMemberTile(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    GroupService groupService,
    GroupMember member,
    bool amAdmin,
    String myPublicKey,
  ) {
    final isMe = member.publicKey == myPublicKey;
    final memberIsAdmin = member.role == GroupRole.admin;

    return ListTile(
      leading: UserAvatar(
        displayName: member.displayName,
        size: AvatarSize.medium,
      ),
      title: Text(
        isMe ? '${member.displayName} (You)' : member.displayName,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: memberIsAdmin
          ? null
          : Text(
              'Member',
              style: theme.textTheme.bodySmall,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (memberIsAdmin)
            Chip(
              label: const Text('Admin'),
              backgroundColor: colorScheme.secondary.withOpacity(0.2),
              labelStyle: TextStyle(
                color: colorScheme.secondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          if (amAdmin && !isMe)
            PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'promote':
                    await groupService.promoteMember(
                        widget.dhtKey, member.publicKey);
                    break;
                  case 'demote':
                    await groupService.demoteMember(
                        widget.dhtKey, member.publicKey);
                    break;
                  case 'remove':
                    await _confirmRemoveMember(
                        context, groupService, member);
                    break;
                }
              },
              itemBuilder: (ctx) => [
                if (!memberIsAdmin)
                  const PopupMenuItem(
                    value: 'promote',
                    child: Text('Make Admin'),
                  ),
                if (memberIsAdmin)
                  const PopupMenuItem(
                    value: 'demote',
                    child: Text('Make Member'),
                  ),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text(
                    'Remove from Group',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
