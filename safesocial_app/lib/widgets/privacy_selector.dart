import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content_privacy.dart';
import '../services/contact_service.dart';
import '../services/group_service.dart';

/// Bottom sheet widget for selecting content privacy level.
class PrivacySelector extends StatelessWidget {
  final PrivacySetting current;
  final ValueChanged<PrivacySetting> onChanged;

  const PrivacySelector({
    super.key,
    required this.current,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => _showPicker(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: current.color.withValues(alpha: 0.5)),
          color: current.color.withValues(alpha: 0.08),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(current.icon, size: 14, color: current.color),
            const SizedBox(width: 4),
            Text(
              current.label,
              style: TextStyle(
                fontSize: 12,
                color: current.color,
                fontWeight: FontWeight.w600,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final contacts = context.read<ContactService>().contacts;
    final groups = context.read<GroupService>().groups;

    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Who can see this?',
                  style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                ),
              ),
              const Divider(),

              // Public
              _PrivacyOption(
                icon: Icons.public,
                label: 'Public',
                subtitle: 'Anyone can see this',
                color: Colors.green,
                selected: current.level == ContentPrivacy.public,
                onTap: () {
                  onChanged(PrivacySetting.defaultPublic);
                  Navigator.pop(ctx);
                },
              ),

              // Only Me
              _PrivacyOption(
                icon: Icons.lock,
                label: 'Only Me',
                subtitle: 'Private — only you can see this',
                color: Colors.red,
                selected: current.level == ContentPrivacy.onlyMe,
                onTap: () {
                  onChanged(PrivacySetting.defaultOnlyMe);
                  Navigator.pop(ctx);
                },
              ),

              // Specific contacts
              if (contacts.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'SPECIFIC PERSON',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                SizedBox(
                  height: contacts.length > 3 ? 150 : contacts.length * 50.0,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: contacts.length,
                    itemBuilder: (ctx, i) {
                      final c = contacts[i];
                      return _PrivacyOption(
                        icon: Icons.person,
                        label: c.displayName,
                        subtitle: 'Only ${c.displayName} can see this',
                        color: Colors.blue,
                        selected: current.level == ContentPrivacy.individual &&
                            current.recipientPublicKey == c.publicKey,
                        onTap: () {
                          onChanged(PrivacySetting(
                            level: ContentPrivacy.individual,
                            recipientPublicKey: c.publicKey,
                            recipientName: c.displayName,
                          ));
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              ],

              // Groups
              if (groups.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'GROUP',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                for (final g in groups)
                  _PrivacyOption(
                    icon: Icons.group,
                    label: g.name,
                    subtitle: 'All members of ${g.name}',
                    color: Colors.purple,
                    selected: current.level == ContentPrivacy.group &&
                        current.groupId == g.dhtKey,
                    onTap: () {
                      onChanged(PrivacySetting(
                        level: ContentPrivacy.group,
                        groupId: g.dhtKey,
                        groupName: g.name,
                      ));
                      Navigator.pop(ctx);
                    },
                  ),
              ],

              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}

class _PrivacyOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _PrivacyOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: selected
          ? Icon(Icons.check_circle, color: color)
          : null,
      onTap: onTap,
    );
  }
}
