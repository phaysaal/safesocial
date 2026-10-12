import 'dart:io';

import 'package:flutter/material.dart';

import '../models/contact.dart';
import '../models/post.dart';
import '../models/profile_about.dart';
import '../models/user_profile.dart';
import '../services/profile_sharing.dart';
import 'avatar.dart';
import 'post_card.dart';

/// One profile as somebody sees it: ours, ours as a chosen audience sees
/// it, or a contact's as they let us see it. The same widget renders all
/// three so "view as" shows exactly what travels.
class ProfileData {
  final String name;
  final String bio;
  final String? birthday;
  final String? avatarRef;
  final String? coverRef;
  final List<String> featuredRefs;
  final List<StoryHighlight> highlights;
  final ProfileAbout about;
  final bool avatarIsTemporary;

  /// A short line for the day, or empty.
  final String statusNote;

  const ProfileData({
    required this.name,
    this.bio = '',
    this.birthday,
    this.avatarRef,
    this.coverRef,
    this.featuredRefs = const [],
    this.highlights = const [],
    this.about = ProfileAbout.empty,
    this.avatarIsTemporary = false,
    this.statusNote = '',
  });

  /// Our own profile, whole.
  factory ProfileData.own(UserProfile p) => ProfileData(
        name: p.displayName,
        bio: p.bio,
        birthday: p.birthday,
        avatarRef: p.avatarRef,
        coverRef: p.coverRef,
        featuredRefs: p.featuredRefs,
        highlights: p.highlights,
        about: p.about,
        avatarIsTemporary: p.avatarIsTemporary,
        statusNote: p.activeNote,
      );

  /// Our own profile as a contact sharing [sharedSpheres] with us sees it.
  factory ProfileData.ownAs(UserProfile p, Set<String> sharedSpheres) {
    final fields = ProfileSharing.visibleFields(p, sharedSpheres);
    return ProfileData(
      name: p.displayName,
      bio: fields.contains(ProfileField.bio) ? p.bio : '',
      birthday: fields.contains(ProfileField.birthday) ? p.birthday : null,
      avatarRef: p.avatarRef,
      coverRef: fields.contains(ProfileField.cover) ? p.coverRef : null,
      featuredRefs:
          fields.contains(ProfileField.featured) ? p.featuredRefs : const [],
      highlights: fields.contains(ProfileField.highlights) ? p.highlights : const [],
      about: p.about.restrictedTo(fields),
      avatarIsTemporary: p.avatarIsTemporary,
      statusNote: fields.contains(ProfileField.note) ? p.activeNote : '',
    );
  }

  factory ProfileData.contact(Contact c) => ProfileData(
        name: c.displayName,
        bio: c.bio,
        birthday: c.birthday,
        avatarRef: c.avatarRef,
        coverRef: c.coverRef,
        featuredRefs: c.featuredRefs,
        highlights: c.highlights,
        about: c.about,
        statusNote: c.activeNote,
      );
}

class ProfileView extends StatelessWidget {
  final ProfileData data;

  /// Turns a contact's identity key into a name we know, or null.
  final String? Function(String key)? resolveName;

  /// Shown under the header: edit buttons for our own, a chat button for a
  /// contact's.
  final Widget? actions;

  /// Something to say above the about section, e.g. "named you their legacy
  /// contact".
  final String? note;

  /// Posts pinned to this profile that the viewer has.
  final List<Post> pinnedPosts;

  /// On our own profile: a long press on a highlight removes it.
  final Future<void> Function(String highlightId)? onRemoveHighlight;

  /// Posts by others that tag this person and may be shown.
  final List<Post> taggedPosts;

  const ProfileView({
    super.key,
    required this.data,
    this.resolveName,
    this.actions,
    this.note,
    this.pinnedPosts = const [],
    this.onRemoveHighlight,
    this.taggedPosts = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final about = data.about;

    String personLabel(NamedPerson p) {
      final known = p.key.isEmpty ? null : resolveName?.call(p.key);
      final name = known ?? (p.label.isNotEmpty ? p.label : 'Someone');
      return p.relation.isEmpty ? name : '$name · ${p.relation}';
    }

    final rows = <(IconData, String, String)>[
      if (about.work.isNotEmpty) (Icons.work_outline, 'Work', about.work),
      if (about.education.isNotEmpty)
        (Icons.school_outlined, 'Education', about.education),
      if (about.city.isNotEmpty) (Icons.location_city, 'Lives in', about.city),
      if (about.hometown.isNotEmpty) (Icons.home_outlined, 'From', about.hometown),
      if (about.relationshipStatus.isNotEmpty || about.partner != null)
        (
          Icons.favorite_border,
          'Relationship',
          [
            if (about.relationshipStatus.isNotEmpty) about.relationshipStatus,
            if (about.partner != null) 'with ${personLabel(about.partner!)}',
          ].join(' '),
        ),
      if (about.family.isNotEmpty)
        (Icons.people_outline, 'Family', about.family.map(personLabel).join(', ')),
      if (about.languages.isNotEmpty)
        (Icons.translate, 'Languages', about.languages.join(', ')),
      if (about.hobbies.isNotEmpty)
        (Icons.interests_outlined, 'Hobbies', about.hobbies.join(', ')),
      if (about.websites.isNotEmpty)
        (Icons.link, 'Websites', about.websites.join('\n')),
      if (data.birthday != null)
        (Icons.cake_outlined, 'Birthday', _birthdayLabel(data.birthday!)),
      if (about.quotes.isNotEmpty) (Icons.format_quote, 'Quotes', about.quotes),
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Cover and picture ────────────────────────────────────
          SizedBox(
            height: 220,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  bottom: 48,
                  child: data.coverRef != null && File(data.coverRef!).existsSync()
                      ? Image.file(File(data.coverRef!), fit: BoxFit.cover)
                      : Container(color: cs.primaryContainer),
                ),
                Positioned(
                  left: 24,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: cs.surface, shape: BoxShape.circle),
                    child: UserAvatar(
                      displayName: data.name,
                      imageRef: data.avatarRef,
                      size: AvatarSize.large,
                    ),
                  ),
                ),
                if (data.avatarIsTemporary)
                  Positioned(
                    left: 110,
                    bottom: 8,
                    child: Chip(
                      label: const Text('Temporary picture',
                          style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Name line ───────────────────────────────────────
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(data.name,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    if (about.pronouns.isNotEmpty)
                      Text(about.pronouns,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
                if (about.nickname.isNotEmpty || about.pronunciation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        if (about.nickname.isNotEmpty) '“${about.nickname}”',
                        if (about.pronunciation.isNotEmpty)
                          'said ${about.pronunciation}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                if (data.statusNote.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Chip(
                      avatar: const Text('💬'),
                      label: Text(data.statusNote),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (data.bio.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(data.bio, style: theme.textTheme.bodyMedium),
                ],
                if (note != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    Icon(Icons.verified_user_outlined, size: 16, color: cs.primary),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(note!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.primary))),
                  ]),
                ],
                if (actions != null) ...[
                  const SizedBox(height: 16),
                  actions!,
                ],

                // ── Story highlights ────────────────────────────────
                if (data.highlights.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _SectionLabel('Highlights'),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 92,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: data.highlights.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (_, i) {
                        final h = data.highlights[i];
                        final cover = h.refs.isEmpty ? null : h.refs.last;
                        return InkWell(
                          onTap: h.refs.isEmpty
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => _HighlightViewer(highlight: h))),
                          onLongPress: onRemoveHighlight == null
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: Text('Remove "${h.title}"?'),
                                      content: const Text('The pictures stay in your story archive.'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                                      ],
                                    ),
                                  );
                                  if (ok == true) await onRemoveHighlight!(h.id);
                                },
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: cs.primary, width: 2),
                                color: cs.surfaceContainerHighest,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: cover != null && File(cover).existsSync()
                                  ? Image.file(File(cover), fit: BoxFit.cover)
                                  : Icon(Icons.auto_awesome_outlined, color: cs.onSurfaceVariant),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 72,
                              child: Text(h.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelSmall),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
                ],

                // ── Featured photos ─────────────────────────────────
                if (data.featuredRefs.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _SectionLabel('Featured'),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: data.featuredRefs.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: File(data.featuredRefs[i]).existsSync()
                            ? Image.file(File(data.featuredRefs[i]),
                                width: 96, height: 96, fit: BoxFit.cover)
                            : Container(
                                width: 96, height: 96, color: cs.surfaceContainerHighest),
                      ),
                    ),
                  ),
                ],

                // ── About ───────────────────────────────────────────
                if (rows.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _SectionLabel('About'),
                  for (final r in rows)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(r.$1, color: cs.secondary),
                      title: Text(r.$3),
                      subtitle: Text(r.$2, style: theme.textTheme.bodySmall),
                    ),
                ],

                // ── Life events ─────────────────────────────────────
                if (about.lifeEvents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _SectionLabel('Life events'),
                  for (final e in about.lifeEvents)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(Icons.flag_outlined, color: cs.secondary),
                      title: Text(e.title),
                      subtitle: Text([
                        if (e.date.isNotEmpty) e.date,
                        if (e.note.isNotEmpty) e.note,
                      ].join(' · ')),
                    ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
          if (taggedPosts.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: _SectionLabel('Tagged in')),
            for (final p in taggedPosts) PostCard(post: p),
          ],
          if (pinnedPosts.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: _SectionLabel('Pinned'),
            ),
            for (final p in pinnedPosts) PostCard(post: p),
          ],
        ],
      ),
    );
  }

  static String _birthdayLabel(String mmdd) {
    final parts = mmdd.split('-');
    if (parts.length != 2) return mmdd;
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', 'July',
      'August', 'September', 'October', 'November', 'December'
    ];
    final m = int.tryParse(parts[0]);
    final d = int.tryParse(parts[1]);
    if (m == null || d == null || m < 1 || m > 12) return mmdd;
    return '$d ${months[m - 1]}';
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(text.toUpperCase(),
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary, letterSpacing: 1.2));
  }
}

/// The pictures of one highlight, full screen, swiped through.
class _HighlightViewer extends StatelessWidget {
  final StoryHighlight highlight;
  const _HighlightViewer({required this.highlight});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(highlight.title),
      ),
      body: PageView.builder(
        itemCount: highlight.refs.length,
        itemBuilder: (_, i) {
          final f = File(highlight.refs[i]);
          return f.existsSync()
              ? InteractiveViewer(child: Center(child: Image.file(f, fit: BoxFit.contain)))
              : const Center(child: Text('Picture not on this device', style: TextStyle(color: Colors.white54)));
        },
      ),
    );
  }
}
