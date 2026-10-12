import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/contact.dart';
import '../../models/profile_about.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../services/relay_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/avatar.dart';

/// Everything a profile can say, with an audience on every field.
///
/// Text fields are saved together with the Save button; pictures, the
/// legacy contact and audiences take effect at once, since each is its own
/// decision and each goes to contacts as a fresh copy.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  final _pronouns = TextEditingController();
  final _nickname = TextEditingController();
  final _pronunciation = TextEditingController();
  final _work = TextEditingController();
  final _education = TextEditingController();
  final _city = TextEditingController();
  final _hometown = TextEditingController();
  final _relationship = TextEditingController();
  final _languages = TextEditingController();
  final _websites = TextEditingController();
  final _hobbies = TextEditingController();
  final _quotes = TextEditingController();

  String? _birthday;
  NamedPerson? _partner;
  List<NamedPerson> _family = [];
  List<LifeEvent> _lifeEvents = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final p = context.read<IdentityService>().currentIdentity;
    if (p == null) return;
    final a = p.about;
    _name.text = p.displayName;
    _bio.text = p.bio;
    _birthday = p.birthday;
    _pronouns.text = a.pronouns;
    _nickname.text = a.nickname;
    _pronunciation.text = a.pronunciation;
    _work.text = a.work;
    _education.text = a.education;
    _city.text = a.city;
    _hometown.text = a.hometown;
    _relationship.text = a.relationshipStatus;
    _languages.text = a.languages.join(', ');
    _websites.text = a.websites.join(', ');
    _hobbies.text = a.hobbies.join(', ');
    _quotes.text = a.quotes;
    _partner = a.partner;
    _family = List.of(a.family);
    _lifeEvents = List.of(a.lifeEvents);
  }

  @override
  void dispose() {
    for (final c in [
      _name, _bio, _pronouns, _nickname, _pronunciation, _work, _education,
      _city, _hometown, _relationship, _languages, _websites, _hobbies, _quotes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _list(TextEditingController c) => c.text
      .split(RegExp(r'[,\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      final identity = context.read<IdentityService>();
      await identity.updateProfile(
        displayName: name,
        bio: _bio.text.trim(),
        birthday: _birthday,
        clearBirthday: _birthday == null,
      );
      await identity.updateAbout(ProfileAbout(
        pronouns: _pronouns.text.trim(),
        nickname: _nickname.text.trim(),
        pronunciation: _pronunciation.text.trim(),
        work: _work.text.trim(),
        education: _education.text.trim(),
        city: _city.text.trim(),
        hometown: _hometown.text.trim(),
        relationshipStatus: _relationship.text.trim(),
        partner: _partner,
        family: _family,
        languages: _list(_languages),
        websites: _list(_websites),
        hobbies: _list(_hobbies),
        quotes: _quotes.text.trim(),
        lifeEvents: _lifeEvents,
      ));
      if (mounted) {
        await identity.publishProfileToRelay(context.read<RelayService>());
      }
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Pictures ──────────────────────────────────────────────────────────

  Future<void> _changeAvatar() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose a picture'),
            onTap: () => Navigator.pop(ctx, 'permanent'),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Temporary picture'),
            subtitle: const Text('The current one comes back when the time is up'),
            onTap: () => Navigator.pop(ctx, 'temporary'),
          ),
          ListTile(
            leading: const Icon(Icons.face_outlined),
            title: const Text('Draw an avatar'),
            subtitle: const Text('A cartoon you, with stickers to match'),
            onTap: () => Navigator.pop(ctx, 'avatar'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'avatar') {
      context.push('/profile/avatar');
      return;
    }
    Duration? temporaryFor;
    if (choice == 'temporary') {
      temporaryFor = await showModalBottomSheet<Duration>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (label, d) in [
              ('One hour', const Duration(hours: 1)),
              ('One day', const Duration(days: 1)),
              ('One week', const Duration(days: 7)),
              ('One month', const Duration(days: 30)),
            ])
              ListTile(title: Text(label), onTap: () => Navigator.pop(ctx, d)),
          ]),
        ),
      );
      if (temporaryFor == null || !mounted) return;
    }
    final picked = choice == 'camera'
        ? await context.read<MediaService>().captureImage(front: true)
        : choice == 'temporary'
            ? await _pickPicture(front: true)
            : await context.read<MediaService>().pickAndStoreImage();
    if (picked == null || !mounted) return;
    final identity = context.read<IdentityService>();
    await identity.updateAvatar(picked, temporaryFor: temporaryFor);
    if (!mounted) return;
    await identity.publishProfileToRelay(context.read<RelayService>());
    if (!mounted) return;
    await _offerPicturePost(picked);
  }

  /// Camera or gallery, the person's choice; null when they back out.
  /// [front] starts the camera on the selfie side.
  Future<String?> _pickPicture({bool front = false}) async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose a picture'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
        ]),
      ),
    );
    if (source == null || !mounted) return null;
    final media = context.read<MediaService>();
    return source == 'camera' ? media.captureImage(front: front) : media.pickAndStoreImage();
  }

  /// "Updated their profile picture", as a post, into the spheres chosen.
  Future<void> _offerPicturePost(String localRef) async {
    final spheres = context.read<SphereService>().spheres;
    if (spheres.isEmpty) return;
    final chosen = <String>{};
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Share the new picture as a post?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Only the spheres you tick see it.',
                  style: TextStyle(fontSize: 12)),
              for (final s in spheres)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: chosen.contains(s.id),
                  title: Text(s.name),
                  onChanged: (v) => setDialogState(() {
                    if (v == true) {
                      chosen.add(s.id);
                    } else {
                      chosen.remove(s.id);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            FilledButton(
                onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, true),
                child: const Text('Post')),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final sphereService = context.read<SphereService>();
    final audience = <String>{
      for (final id in chosen)
        ...?sphereService.sphere(id)?.members.map((m) => m.identityKey),
    };
    await context.read<FeedService>().createPost(
          'Updated their profile picture',
          sphereIds: chosen,
          audienceMembers: audience.toList(),
          mediaRefs: [localRef],
          authorName: context.read<IdentityService>().currentIdentity?.displayName,
        );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Posted')));
    }
  }

  Future<void> _changeCover() async {
    final identity = context.read<IdentityService>();
    final current = identity.currentIdentity?.coverRef;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose a cover photo'),
            onTap: () => Navigator.pop(ctx, 'pick'),
          ),
          if (current != null)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove cover photo'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'remove') {
      await identity.updateCover(null);
      return;
    }
    final media = context.read<MediaService>();
    final picked = action == 'camera' ? await media.captureImage() : await media.pickAndStoreImage();
    if (picked != null) await identity.updateCover(picked);
  }

  Future<void> _addFeatured() async {
    final identity = context.read<IdentityService>();
    final current = identity.currentIdentity?.featuredRefs ?? const [];
    if (current.length >= 6) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Six featured photos is the most')));
      return;
    }
    final picked = await _pickPicture();
    if (picked != null) await identity.updateFeatured([...current, picked]);
  }

  // ── Audience ──────────────────────────────────────────────────────────

  Future<void> _pickAudience(String field) async {
    final identity = context.read<IdentityService>();
    final spheres = context.read<SphereService>().spheres;
    final current = identity.currentIdentity?.audience[field] ?? FieldAudience.contacts;
    final selected = Set<String>.from(current.sphereIds);
    var mode = current.mode;
    final result = await showDialog<FieldAudience>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Who sees ${ProfileField.label(field).toLowerCase()}?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'contacts',
                  groupValue: mode,
                  title: const Text('All contacts'),
                  onChanged: (v) => setDialogState(() => mode = v!),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'spheres',
                  groupValue: mode,
                  title: const Text('Only people in these spheres'),
                  onChanged: spheres.isEmpty ? null : (v) => setDialogState(() => mode = v!),
                ),
                if (mode == 'spheres')
                  for (final s in spheres)
                    CheckboxListTile(
                      contentPadding: const EdgeInsets.only(left: 24),
                      dense: true,
                      value: selected.contains(s.id),
                      title: Text(s.name),
                      onChanged: (v) => setDialogState(() {
                        if (v == true) {
                          selected.add(s.id);
                        } else {
                          selected.remove(s.id);
                        }
                      }),
                    ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: 'me',
                  groupValue: mode,
                  title: const Text('Only me'),
                  subtitle: const Text('Kept on this device; never sent',
                      style: TextStyle(fontSize: 11)),
                  onChanged: (v) => setDialogState(() => mode = v!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                mode == 'contacts'
                    ? FieldAudience.contacts
                    : mode == 'me'
                        ? FieldAudience.me
                        : FieldAudience.spheres(selected),
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await identity.setFieldAudience(field, result);
  }

  Widget _audienceChip(String field) {
    final identity = context.watch<IdentityService>();
    final spheres = context.read<SphereService>();
    final a = identity.currentIdentity?.audience[field] ?? FieldAudience.contacts;
    return ActionChip(
      avatar: Icon(
        a.isMe ? Icons.lock_outline : a.isSpheres ? Icons.blur_circular : Icons.people_outline,
        size: 16,
      ),
      label: Text(a.describe((id) => spheres.sphere(id)?.name ?? 'a sphere'),
          style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      onPressed: () => _pickAudience(field),
    );
  }

  Widget _field(String field, TextEditingController c,
      {String? hint, int lines = 1, bool audience = true}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: c,
            maxLines: lines,
            decoration: InputDecoration(
              labelText: ProfileField.label(field),
              hintText: hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (audience)
            Padding(padding: const EdgeInsets.only(top: 4), child: _audienceChip(field)),
        ],
      ),
    );
  }

  // ── People pickers ─────────────────────────────────────────────────────

  Future<Contact?> _pickContact(String title) {
    final contacts = context.read<ContactService>().contacts.where((c) => !c.blocked).toList();
    return showModalBottomSheet<Contact>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(title)),
            if (contacts.isEmpty) const ListTile(title: Text('No contacts yet')),
            for (final c in contacts)
              ListTile(
                leading: UserAvatar(
                    displayName: c.displayName, imageRef: c.avatarRef, size: AvatarSize.small),
                title: Text(c.displayName),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _addFamily() async {
    final c = await _pickContact('Who?');
    if (c == null || !mounted) return;
    final relation = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c.displayName),
        content: TextField(
          controller: relation,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Relation', hintText: 'sister, father, cousin…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _family = [
            ..._family,
            NamedPerson(key: c.publicKey, label: c.displayName, relation: relation.text.trim()),
          ]);
    }
  }

  Future<void> _addLifeEvent() async {
    final title = TextEditingController();
    final date = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Life event'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'What')),
          TextField(controller: date, decoration: const InputDecoration(labelText: 'When', hintText: '2024-06')),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      setState(() => _lifeEvents = [
            ..._lifeEvents,
            LifeEvent(title: title.text.trim(), date: date.text.trim(), note: note.text.trim()),
          ]);
    }
  }

  Future<void> _pickLegacyContact() async {
    final identity = context.read<IdentityService>();
    if (identity.currentIdentity?.legacyContact != null) {
      final clear = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Legacy contact'),
          content: const Text('Choose someone else, or remove the current one?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
            FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Choose')),
          ],
        ),
      );
      if (clear == null || !mounted) return;
      if (clear) {
        await identity.setLegacyContact(null);
        return;
      }
    }
    final c = await _pickContact('Who speaks for you if you cannot?');
    if (c != null) await identity.setLegacyContact(c.publicKey);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identity = context.watch<IdentityService>();
    final profile = identity.currentIdentity;
    final contacts = context.watch<ContactService>();
    final spheres = context.watch<SphereService>();
    String nameOf(String key) =>
        contacts.contacts.where((c) => c.publicKey == key).map((c) => c.displayName).firstOrNull ??
        'a contact no longer in your list';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Pictures ────────────────────────────────────────────
          SizedBox(
            height: 180,
            child: Stack(
              children: [
                Positioned.fill(
                  bottom: 40,
                  child: InkWell(
                    onTap: _changeCover,
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                        image: profile?.coverRef != null && File(profile!.coverRef!).existsSync()
                            ? DecorationImage(image: FileImage(File(profile.coverRef!)), fit: BoxFit.cover)
                            : null,
                      ),
                      alignment: Alignment.topRight,
                      padding: const EdgeInsets.all(8),
                      child: const Chip(
                          avatar: Icon(Icons.photo_camera_outlined, size: 16),
                          label: Text('Cover', style: TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  bottom: 0,
                  child: Stack(children: [
                    UserAvatar(
                        displayName: profile?.displayName ?? '?',
                        imageRef: profile?.avatarRef,
                        size: AvatarSize.large),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: CircleAvatar(
                        backgroundColor: cs.primary,
                        radius: 18,
                        child: IconButton(
                          icon: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
                          onPressed: _changeAvatar,
                        ),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          if (profile?.avatarIsTemporary == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Temporary picture until ${profile!.avatarUntil!.toLocal().toString().substring(0, 16)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Row(children: [
            Expanded(child: Text('Cover photo', style: theme.textTheme.bodySmall)),
            _audienceChip(ProfileField.cover),
          ]),
          const SizedBox(height: 16),

          // ── Name and basics ─────────────────────────────────────
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: 'Display name', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 12),
          _field(ProfileField.pronouns, _pronouns, hint: 'she/her, he/him, they/them'),
          _field(ProfileField.nickname, _nickname),
          _field(ProfileField.pronunciation, _pronunciation, hint: 'FAY-sal'),
          _field(ProfileField.bio, _bio, lines: 3),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.cake_outlined, color: cs.primary),
            title: Text(_birthday == null ? 'Birthday' : 'Birthday · $_birthday'),
            subtitle: const Text('Day and month only, so contacts get a reminder', style: TextStyle(fontSize: 11)),
            trailing: _birthday == null
                ? const Icon(Icons.chevron_right)
                : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _birthday = null)),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime(2000, 1, 1),
                firstDate: DateTime(2000, 1, 1),
                lastDate: DateTime(2000, 12, 31),
                helpText: 'Pick the day; the year is not kept',
              );
              if (picked != null) {
                setState(() => _birthday =
                    '${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
              }
            },
          ),
          _audienceChip(ProfileField.birthday),
          const Divider(height: 32),

          // ── Featured ────────────────────────────────────────────
          Row(children: [
            Expanded(child: Text('Featured photos', style: theme.textTheme.titleSmall)),
            _audienceChip(ProfileField.featured),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final (i, ref) in (profile?.featuredRefs ?? const <String>[]).indexed)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Stack(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: File(ref).existsSync()
                            ? Image.file(File(ref), width: 80, height: 80, fit: BoxFit.cover)
                            : Container(width: 80, height: 80, color: cs.surfaceContainerHighest),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: InkWell(
                          onTap: () {
                            final next = List<String>.from(profile!.featuredRefs)..removeAt(i);
                            identity.updateFeatured(next);
                          },
                          child: const CircleAvatar(
                              radius: 11, backgroundColor: Colors.black54,
                              child: Icon(Icons.close, size: 14, color: Colors.white)),
                        ),
                      ),
                    ]),
                  ),
                InkWell(
                  onTap: _addFeatured,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                        border: Border.all(color: cs.outline), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Icons.add),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 32),

          // ── About ───────────────────────────────────────────────
          Text('About', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _field(ProfileField.work, _work),
          _field(ProfileField.education, _education),
          _field(ProfileField.city, _city),
          _field(ProfileField.hometown, _hometown),
          _field(ProfileField.relationship, _relationship, hint: 'single, married, it\'s complicated…'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.favorite_border),
            title: Text(_partner == null ? 'Partner (optional)' : 'With ${nameOf(_partner!.key)}'),
            trailing: _partner == null
                ? const Icon(Icons.chevron_right)
                : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _partner = null)),
            onTap: () async {
              final c = await _pickContact('Your partner');
              if (c != null) {
                setState(() => _partner =
                    NamedPerson(key: c.publicKey, label: c.displayName, relation: 'partner'));
              }
            },
          ),
          Row(children: [
            Expanded(child: Text('Family', style: theme.textTheme.bodyMedium)),
            _audienceChip(ProfileField.family),
          ]),
          for (final (i, p) in _family.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.people_outline),
              title: Text(nameOf(p.key)),
              subtitle: Text(p.relation),
              trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _family = List.of(_family)..removeAt(i))),
            ),
          TextButton.icon(
              onPressed: _addFamily, icon: const Icon(Icons.add), label: const Text('Add a family member')),
          const SizedBox(height: 8),
          _field(ProfileField.languages, _languages, hint: 'Bangla, English, French'),
          _field(ProfileField.hobbies, _hobbies, hint: 'comma separated'),
          _field(ProfileField.websites, _websites, hint: 'comma separated'),
          _field(ProfileField.quotes, _quotes, lines: 3),
          Row(children: [
            Expanded(child: Text('Life events', style: theme.textTheme.bodyMedium)),
            _audienceChip(ProfileField.lifeEvents),
          ]),
          for (final (i, e) in _lifeEvents.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.flag_outlined),
              title: Text(e.title),
              subtitle: Text([if (e.date.isNotEmpty) e.date, if (e.note.isNotEmpty) e.note].join(' · ')),
              trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _lifeEvents = List.of(_lifeEvents)..removeAt(i))),
            ),
          TextButton.icon(
              onPressed: _addLifeEvent, icon: const Icon(Icons.add), label: const Text('Add a life event')),
          const Divider(height: 32),

          // ── Legacy contact ──────────────────────────────────────
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.verified_user_outlined, color: cs.primary),
            title: const Text('Legacy contact'),
            subtitle: Text(
              profile?.legacyContact == null
                  ? 'Someone who speaks for this profile if you cannot. They are told; nobody else is. '
                      'Social Recovery in Settings suggests them as a guardian.'
                  : nameOf(profile!.legacyContact!),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickLegacyContact,
          ),
          if (spheres.spheres.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                'You are in no sphere yet, so every audience is "all contacts" or "only me".',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
