import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sphere_info.dart';
import '../../services/library_service.dart';
import '../../services/sphere_info_service.dart';
import '../../services/sphere_service.dart';

/// Rules, join questions, topics, the welcome line and the automation an
/// admin chose for a sphere. Everything but the keyword list travels to every
/// member as one signed item; the keywords stay on this device.
class SphereSettingsScreen extends StatefulWidget {
  final String sphereId;
  const SphereSettingsScreen({super.key, required this.sphereId});

  @override
  State<SphereSettingsScreen> createState() => _SphereSettingsScreenState();
}

class _SphereSettingsScreenState extends State<SphereSettingsScreen> {
  final _rules = TextEditingController();
  final _questions = List.generate(3, (_) => TextEditingController());
  final _topics = TextEditingController();
  final _welcome = TextEditingController();
  final _keywords = TextEditingController();
  int _autoMute = 0;
  int _inviteDays = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final info = context.read<SphereInfoService>().infoFor(widget.sphereId);
    _rules.text = info.rules.join('\n');
    for (var i = 0; i < 3; i++) {
      _questions[i].text = i < info.questions.length ? info.questions[i] : '';
    }
    _topics.text = info.topics.join(', ');
    _welcome.text = info.welcome;
    _autoMute = info.autoMuteReports;
    _inviteDays = info.inviteDays;
    _keywords.text = context.read<LibraryService>().adminKeywords(widget.sphereId).join(', ');
  }

  @override
  void dispose() {
    _rules.dispose();
    for (final q in _questions) {
      q.dispose();
    }
    _topics.dispose();
    _welcome.dispose();
    _keywords.dispose();
    super.dispose();
  }

  List<String> _lines(String s) => s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  List<String> _commas(String s) => s.split(',').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<LibraryService>().setAdminKeywords(widget.sphereId, _commas(_keywords.text));
      await context.read<SphereInfoService>().update(
          widget.sphereId,
          (c) => c.copyWith(
                rules: _lines(_rules.text).take(20).toList(),
                questions: _questions.map((q) => q.text.trim()).where((q) => q.isNotEmpty).toList(),
                topics: _commas(_topics.text).take(20).toList(),
                welcome: _welcome.text.trim(),
                autoMuteReports: _autoMute,
                inviteDays: _inviteDays,
              ));
      messenger.showSnackBar(const SnackBar(content: Text('Saved and sent to every member')));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sphere = context.watch<SphereService>().sphere(widget.sphereId);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(sphere == null ? 'Sphere settings' : '${sphere.name} · settings'),
        actions: [
          TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Rules', style: theme.textTheme.titleMedium),
          Text('One per line. Shown to every member until they say they have read them, and again whenever they change.',
              style: theme.textTheme.bodySmall),
          TextField(controller: _rules, minLines: 3, maxLines: 10, decoration: const InputDecoration(hintText: 'Be kind.\nNo screenshots.')),
          const SizedBox(height: 20),
          Text('Membership questions', style: theme.textTheme.titleMedium),
          Text('Up to three. They ride in the invite link and are answered in the request you approve.',
              style: theme.textTheme.bodySmall),
          for (final (i, q) in _questions.indexed)
            TextField(controller: q, decoration: InputDecoration(labelText: 'Question ${i + 1}')),
          const SizedBox(height: 20),
          Text('Post topics', style: theme.textTheme.titleMedium),
          Text('Separated by commas. Writers pick one when posting here; readers filter by it.',
              style: theme.textTheme.bodySmall),
          TextField(controller: _topics, decoration: const InputDecoration(hintText: 'Announcements, Questions, Photos')),
          const SizedBox(height: 20),
          Text('Welcome post', style: theme.textTheme.titleMedium),
          Text('Posted by the admin who approves a join. {name} becomes the newcomer\'s name.',
              style: theme.textTheme.bodySmall),
          TextField(controller: _welcome, maxLines: 3, decoration: const InputDecoration(hintText: 'Welcome, {name}!')),
          const SizedBox(height: 20),
          Text('Automation', style: theme.textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mute after reports'),
            subtitle: Text(_autoMute == 0
                ? 'Off. Reports only land in the admins\' list.'
                : 'When $_autoMute member${_autoMute == 1 ? '' : 's'} have reported someone\'s posts, every admin\'s device mutes them there. Nothing is deleted and they are not told.'),
            trailing: DropdownButton<int>(
              value: _autoMute,
              items: [for (final n in const [0, 2, 3, 5, 10]) DropdownMenuItem(value: n, child: Text(n == 0 ? 'Off' : '$n'))],
              onChanged: (v) => setState(() => _autoMute = v ?? 0),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Invite links expire'),
            subtitle: Text(_inviteDays == 0
                ? 'Never, until an admin resets the link.'
                : 'A link older than $_inviteDays day${_inviteDays == 1 ? '' : 's'} is retired the next time it is shown.'),
            trailing: DropdownButton<int>(
              value: _inviteDays,
              items: [for (final n in const [0, 1, 7, 30, 90]) DropdownMenuItem(value: n, child: Text(n == 0 ? 'Never' : '$n d'))],
              onChanged: (v) => setState(() => _inviteDays = v ?? 0),
            ),
          ),
          const SizedBox(height: 20),
          Text('Keyword alerts (only on this device)', style: theme.textTheme.titleMedium),
          Text('Separated by commas. A post, comment or chat message from someone else containing one of these raises a notification for you. The list never leaves this phone.',
              style: theme.textTheme.bodySmall),
          TextField(controller: _keywords, decoration: const InputDecoration(hintText: 'for sale, crypto')),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save and send to members'),
          ),
          const SizedBox(height: 8),
          Text(
            'Version ${context.watch<SphereInfoService>().infoFor(widget.sphereId).version} of these settings is what members hold.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          const _UnitsNote(),
        ],
      ),
    );
  }
}

class _UnitsNote extends StatelessWidget {
  const _UnitsNote();
  @override
  Widget build(BuildContext context) => Text(
        'Guides (ordered sets of posts) are made from the Guides page; a post is added to one from its menu.',
        style: Theme.of(context).textTheme.bodySmall,
      );
}

/// Pick badges for a member.
Future<void> showBadgesDialog(BuildContext context, String sphereId, String member, String name) async {
  final info = context.read<SphereInfoService>();
  final chosen = {...info.badgesFor(sphereId, member)};
  final custom = TextEditingController();
  const presets = ['Expert', 'Founder', 'Moderator', 'Helper', 'Veteran', 'Guest'];
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text('Badges for $name'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(spacing: 6, children: [
            for (final b in {...presets, ...chosen})
              FilterChip(
                label: Text(b),
                selected: chosen.contains(b),
                onSelected: (on) => setD(() => on ? chosen.add(b) : chosen.remove(b)),
              ),
          ]),
          TextField(
            controller: custom,
            decoration: const InputDecoration(labelText: 'Another badge'),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) setD(() => chosen.add(v.trim()));
              custom.clear();
            },
          ),
          const Text('Badges show beside their name in this sphere. Up to five.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await info.update(sphereId, (c) {
      final badges = Map<String, List<String>>.from(c.badges);
      if (chosen.isEmpty) {
        badges.remove(member);
      } else {
        badges[member] = chosen.take(5).toList();
      }
      return c.copyWith(badges: badges);
    });
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// Suspend a member for a period, or lift a suspension.
Future<void> showSuspendDialog(BuildContext context, String sphereId, String member, String name) async {
  final info = context.read<SphereInfoService>();
  final until = info.suspendedUntil(sphereId, member);
  final choice = await showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          title: Text(until == null ? 'Suspend $name' : '$name is suspended until ${until.day}/${until.month} ${until.hour}:${until.minute.toString().padLeft(2, '0')}'),
          subtitle: const Text('Their posts, comments and chat messages are not shown to anyone while it lasts, and their device refuses to send them. Nothing is deleted.'),
        ),
        for (final (days, label) in const [(1, 'One day'), (7, 'One week'), (30, 'Thirty days')])
          ListTile(leading: const Icon(Icons.pause_circle_outline), title: Text(label), onTap: () => Navigator.pop(ctx, days)),
        if (until != null)
          ListTile(leading: const Icon(Icons.play_circle_outline), title: const Text('Lift the suspension'), onTap: () => Navigator.pop(ctx, 0)),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await info.update(sphereId, (c) {
      final s = Map<String, DateTime>.from(c.suspended);
      if (choice == 0) {
        s.remove(member);
      } else {
        s[member] = DateTime.now().add(Duration(days: choice));
      }
      return c.copyWith(suspended: s);
    });
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// Add a post to a guide, new or existing.
Future<void> showAddToGuideDialog(BuildContext context, String sphereId, String postId) async {
  final info = context.read<SphereInfoService>();
  final units = info.infoFor(sphereId).units;
  final title = TextEditingController();
  final chosen = await showDialog<String?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Add to a guide'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final u in units)
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(u.title),
            subtitle: Text('${u.postIds.length} post${u.postIds.length == 1 ? '' : 's'}'),
            onTap: () => Navigator.pop(ctx, u.id),
          ),
        TextField(controller: title, decoration: const InputDecoration(labelText: 'New guide'), onSubmitted: (_) => Navigator.pop(ctx, '')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Create')),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (chosen.isEmpty && title.text.trim().isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('Give the guide a name.')));
    return;
  }
  try {
    await info.update(sphereId, (c) {
      final list = List<SphereUnit>.from(c.units);
      final i = list.indexWhere((u) => u.id == chosen);
      if (i == -1) {
        list.add(SphereUnit(id: DateTime.now().microsecondsSinceEpoch.toRadixString(36), title: title.text.trim(), postIds: [postId]));
      } else if (!list[i].postIds.contains(postId)) {
        list[i] = list[i].copyWith(postIds: [...list[i].postIds, postId]);
      }
      return c.copyWith(units: list.take(20).toList());
    });
    messenger.showSnackBar(const SnackBar(content: Text('Added to the guide')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}
