import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/removal_vote.dart';
import '../../models/sphere.dart';
import 'group_call.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import 'package:flutter/services.dart';

import '../../services/feed_service.dart';
import '../../services/library_service.dart';
import '../../services/sphere_info_service.dart';
import '../../services/sphere_service.dart';
import 'sphere_settings_screen.dart';
import '../../widgets/qr_box.dart';
import '../../widgets/avatar.dart';

/// Members and settings for one sphere.
class SphereDetailScreen extends StatelessWidget {
  final String sphereId;
  const SphereDetailScreen({super.key, required this.sphereId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sphereService = context.watch<SphereService>();
    final sphere = sphereService.sphere(sphereId);
    final me = context.watch<IdentityService>().publicKey;

    if (sphere == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This sphere is no longer available.')),
      );
    }

    final iAmAdmin = me != null && sphere.isAdmin(me);
    final iAmOwner = me != null && sphere.isOwner(me);
    final contacts = context.watch<ContactService>();
    final infoService = context.watch<SphereInfoService>();
    final info = infoService.infoFor(sphereId);
    final unseenRules = infoService.unseenRules(sphereId);
    final mySuspension = me == null ? null : infoService.suspendedUntil(sphereId, me);
    final offer = sphereService.ownershipOfferFor(sphereId);
    final proposals = sphereService
        .proposalsFor(sphereId)
        .where((p) =>
            sphereService.tallyFor(p).outcome == RemovalOutcome.open)
        .toList();

    String nameFor(String key) {
      if (key == me) return 'You';
      for (final contact in contacts.contacts) {
        if (contact.publicKey == key) return contact.displayName;
      }
      // Not a contact: the name they sign their posts with, if we hold any.
      return context.read<FeedService>().authorNameFor(key) ?? '${key.substring(0, 8)}…';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(sphere.name),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'add') {
                _showAddMember(context, sphere);
              } else {
                context.push('/sphere/$sphereId/$v');
              }
            },
            itemBuilder: (_) => [
              if (iAmAdmin) const PopupMenuItem(value: 'add', child: ListTile(leading: Icon(Icons.person_add_outlined), title: Text('Add member'))),
              const PopupMenuItem(value: 'log', child: ListTile(leading: Icon(Icons.history), title: Text('Activity'))),
            ],
          ),
        ],
      ),
      body: ListView(
        children: [
          if (mySuspension != null)
            Container(
              width: double.infinity,
              color: cs.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                'You are suspended here until ${mySuspension.day}/${mySuspension.month} ${mySuspension.hour}:${mySuspension.minute.toString().padLeft(2, '0')}. Your posts and messages are not sent or shown meanwhile.',
                style: TextStyle(color: cs.onErrorContainer),
              ),
            ),
          if (unseenRules.isNotEmpty)
            Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Rules of ${sphere.name}', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  for (final (i, r) in unseenRules.indexed) Text('${i + 1}. $r'),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => infoService.markRulesSeen(sphereId),
                      child: const Text('I have read them'),
                    ),
                  ),
                ]),
              ),
            )
          else if (info.rules.isNotEmpty)
            ExpansionTile(
              leading: Icon(Icons.gavel_outlined, color: cs.primary),
              title: Text('${info.rules.length} rule${info.rules.length == 1 ? '' : 's'}'),
              children: [for (final (i, r) in info.rules.indexed) ListTile(dense: true, title: Text('${i + 1}. $r'))],
            ),
          if (info.topics.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(spacing: 6, children: [for (final t in info.topics) Chip(label: Text(t), visualDensity: VisualDensity.compact)]),
            ),
          if (offer != null)
            _OwnershipOfferBanner(
              sphere: sphere,
              offeredBy: nameFor(offer.by),
              onAccept: () => _acceptOwnership(context, sphere),
            ),
          ...proposals.map((proposal) => _RemovalVoteCard(
                proposal: proposal,
                tally: sphereService.tallyFor(proposal),
                closesAt: sphereService.closesAt(proposal),
                subjectName: nameFor(proposal.subject),
                proposerName: nameFor(proposal.by),
                myVote: sphereService.myVoteOn(proposal.id),
                canVote: me != null &&
                    me != proposal.by &&
                    me != proposal.subject,
                onVote: (inFavour) => _castVote(
                    context, proposal.id, inFavour: inFavour),
              )),
          // Header: name, members at a glance, the main actions.
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [cs.primary.withValues(alpha: 0.14), cs.secondary.withValues(alpha: 0.10)],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(16)),
                  child: const Icon(Icons.blur_on, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(sphere.name, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    Text('${sphere.members.length} member${sphere.members.length == 1 ? '' : 's'} · private',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ]),
                ),
                SizedBox(
                  width: 24.0 + 18.0 * (sphere.members.length.clamp(1, 4) - 1),
                  height: 28,
                  child: Stack(children: [
                    for (final (i, m) in sphere.members.take(4).toList().indexed)
                      Positioned(
                        left: i * 18.0,
                        child: Container(
                          padding: const EdgeInsets.all(1.5),
                          decoration: BoxDecoration(color: cs.surface, shape: BoxShape.circle),
                          child: UserAvatar(displayName: nameFor(m.identityKey), identityKey: m.identityKey, size: AvatarSize.small),
                        ),
                      ),
                  ]),
                ),
              ]),
              if (sphere.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(sphere.description, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 12),
              Row(children: [
                _HeaderAction(icon: Icons.forum_outlined, tooltip: 'Sphere chat', onTap: () => context.push('/sphere/$sphereId/chat')),
                _HeaderAction(icon: Icons.photo_library_outlined, tooltip: 'Media and files', onTap: () => context.push('/sphere/$sphereId/media')),
                if (sphere.members.length > 1)
                  _HeaderAction(icon: Icons.videocam_outlined, tooltip: 'Start a group call', onTap: () => startGroupCallFlow(context, sphere)),
                _HeaderAction(icon: Icons.menu_book_outlined, tooltip: 'Guides', onTap: () => context.push('/sphere/$sphereId/guides')),
                _HeaderAction(icon: Icons.history, tooltip: 'Activity', onTap: () => context.push('/sphere/$sphereId/log')),
                if (iAmAdmin)
                  _HeaderAction(icon: Icons.tune, tooltip: 'Rules, topics, automation', onTap: () => context.push('/sphere/$sphereId/settings')),
              ]),
            ]),
          ),
          if (iAmAdmin) ...[
            ...sphereService.joinRequestsFor(sphereId).map((r) => ListTile(
                  leading: Icon(Icons.person_add_alt_1, color: cs.primary),
                  title: Text('${r['name'] ?? 'Someone'} asked to join'),
                  subtitle: Text(r['answers'] is List && (r['answers'] as List).isNotEmpty
                      ? [
                          for (final (i, a) in (r['answers'] as List).indexed)
                            '${i < info.questions.length ? info.questions[i] : 'Q${i + 1}'}: $a'
                        ].join('\n')
                      : 'Came through your invite link'),
                  isThreeLine: r['answers'] is List && (r['answers'] as List).isNotEmpty,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => sphereService.rejectJoin(sphereId, r['publicKey'] as String),
                    ),
                    IconButton(
                      icon: Icon(Icons.check, color: cs.primary),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await sphereService.approveJoin(sphereId, r['publicKey'] as String);
                          messenger.showSnackBar(SnackBar(content: Text('${r['name']} added')));
                        } catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text('$e')));
                        }
                      },
                    ),
                  ]),
                )),
            ...context.watch<FeedService>().reportsFor(sphereId).map((r) => ListTile(
                  leading: Icon(Icons.flag_outlined, color: cs.error),
                  title: Text('Reported: ${r['reason']}'),
                  subtitle: Text('by ${nameFor(r['by'] as String)}'),
                  onTap: () => context.push('/post/${r['post_id']}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.done),
                    tooltip: 'Dismiss',
                    onPressed: () => context
                        .read<FeedService>()
                        .dismissReport(sphereId, r['post_id'] as String, r['by'] as String),
                  ),
                )),
            ListTile(
              leading: Icon(Icons.link, color: cs.primary),
              title: const Text('Invite link'),
              subtitle: const Text('Anyone with it can ask to join; you still say yes'),
              onTap: () => _showInviteLink(context, sphereService, sphereId),
            ),
          ],
          if (iAmAdmin)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit name and description'),
                  onPressed: () => _showEditDetails(context, sphere),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              // Surfacing the epoch is deliberate: it is the thing that makes
              // removal real, and it explains why an old member stops seeing
              // new posts.
              'Membership version ${sphere.epoch} · '
              '${sphere.members.length} member${sphere.members.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const Divider(),
          ...sphere.members.map((member) {
            final isMe = member.identityKey == me;
            return ListTile(
              leading: UserAvatar(displayName: nameFor(member.identityKey), identityKey: member.identityKey),
              title: Text(nameFor(member.identityKey)),
              subtitle: Builder(builder: (context) {
                final note = context.watch<LibraryService>().memberNote(sphereId, member.identityKey);
                final badges = info.badgesOf(member.identityKey);
                final until = infoService.suspendedUntil(sphereId, member.identityKey);
                return Text([
                  _roleLabel(member.role),
                  if (badges.isNotEmpty) badges.join(', '),
                  if (until != null) 'suspended until ${until.day}/${until.month}',
                  if (note != null) note,
                ].join(' · '));
              }),
              trailing: _memberMenu(
                context: context,
                sphere: sphere,
                member: member,
                isMe: isMe,
                iAmAdmin: iAmAdmin,
                iAmOwner: iAmOwner,
              ),
            );
          }),
          const Divider(),
          if (iAmOwner && (sphere.members.length == 1 || sphere.admins.length == 1))
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.errorContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.shield_outlined, size: 18, color: cs.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    sphere.members.length == 1
                        ? 'You are the only member. Nobody else can re-key this sphere, so add someone and make them an admin before you rely on it.'
                        : 'You are the only admin. If you lose this device nobody can invite or remove anyone here again. Making a second admin costs nothing.',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer),
                  ),
                ),
              ]),
            ),
          ListTile(
            leading: Icon(Icons.logout, color: cs.error),
            title: Text('Leave sphere', style: TextStyle(color: cs.error)),
            subtitle: Text(iAmOwner && sphere.members.length > 1
                ? 'Ownership passes to '
                    '${nameFor(sphere.successorAfter(me) ?? '')}'
                : 'You will lose access to its content'),
            onTap: () => _confirmLeave(context, sphere, nameFor),
          ),
        ],
      ),
    );
  }

  /// Ring everyone in the sphere.
  ///
  /// Group calls had no entry point after the old group screens were retired,
  /// so the mesh code was unreachable.
  static String _roleLabel(SphereRole role) {
    switch (role) {
      case SphereRole.owner:
        return 'Owner';
      case SphereRole.admin:
        return 'Admin';
      case SphereRole.member:
        return 'Member';
    }
  }

  /// What this viewer may do to this member.
  ///
  /// The rules are narrower than "admins can do anything": only the owner can
  /// take admin away from someone else or hand the sphere on, and stepping
  /// down yourself is always available.
  Widget? _memberMenu({
    required BuildContext context,
    required Sphere sphere,
    required SphereMember member,
    required bool isMe,
    required bool iAmAdmin,
    required bool iAmOwner,
  }) {
    final canPromote = iAmAdmin && !isMe && !member.isAdmin;
    final canDemoteThem = iAmOwner && !isMe && member.isAdmin && !member.isOwner;
    final canStepDown = isMe && member.isAdmin && !member.isOwner;
    final canRemove = iAmAdmin && !isMe && !member.isOwner;
    final canHandOver = iAmOwner && !isMe;

    // Anyone may put it to the sphere, including members with no other powers
    // — that is the point of having a vote at all.
    final canPropose = !isMe &&
        !iAmAdmin &&
        removalProposalRefusal(
              sphere: sphere,
              proposer: context.read<IdentityService>().publicKey ?? '',
              subject: member.identityKey,
            ) ==
            null;

    final canMute = !isMe;
    final muted = context.read<LibraryService>().isMemberMuted(sphere.id, member.identityKey);

    if (!canPromote &&
        !canDemoteThem &&
        !canStepDown &&
        !canRemove &&
        !canHandOver &&
        !canPropose &&
        !canMute &&
        !iAmAdmin) {
      return null;
    }

    return PopupMenuButton<String>(
      onSelected: (action) => _onMemberAction(context, sphere, member, action),
      itemBuilder: (_) => [
        if (canMute)
          PopupMenuItem(
              value: 'mute',
              child: Text(muted ? 'Unmute in this sphere' : 'Mute in this sphere')),
        if (!isMe) const PopupMenuItem(value: 'note', child: Text('Private note…')),
        if (iAmAdmin) const PopupMenuItem(value: 'badges', child: Text('Badges…')),
        if (iAmAdmin && !isMe) const PopupMenuItem(value: 'suspend', child: Text('Suspend…')),
        if (canPromote)
          const PopupMenuItem(value: 'promote', child: Text('Make admin')),
        if (canDemoteThem)
          const PopupMenuItem(value: 'demote', child: Text('Remove as admin')),
        if (canStepDown)
          const PopupMenuItem(value: 'demote', child: Text('Step down as admin')),
        if (canHandOver)
          const PopupMenuItem(
              value: 'transfer', child: Text('Offer ownership…')),
        if (canRemove)
          const PopupMenuItem(
              value: 'remove', child: Text('Remove from sphere')),
        if (canPropose)
          const PopupMenuItem(
              value: 'propose', child: Text('Propose removal…')),
      ],
    );
  }

  Future<void> _showInviteLink(BuildContext context, SphereService service, String sphereId) async {
    final messenger = ScaffoldMessenger.of(context);
    String link;
    try {
      final info = context.read<SphereInfoService>().infoFor(sphereId);
      link = service.inviteLink(sphereId,
          questions: info.questions,
          maxAge: info.inviteDays == 0 ? null : Duration(days: info.inviteDays));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invite link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Whoever opens this can ask to join. Their request lands here and you '
              'approve it, which also makes them a contact. Reset the link to '
              'retire every copy of it.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            QrBox(data: link),
            const SizedBox(height: 8),
            SelectableText(link, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await service.rotateInviteLink(sphereId);
              if (ctx.mounted) Navigator.pop(ctx);
              messenger.showSnackBar(const SnackBar(content: Text('Old links no longer work')));
            },
            child: const Text('Reset link'),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              messenger.showSnackBar(const SnackBar(content: Text('Link copied')));
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _onMemberAction(
    BuildContext context,
    Sphere sphere,
    SphereMember member,
    String action,
  ) async {
    if (action == 'note') {
      final library = context.read<LibraryService>();
      final controller =
          TextEditingController(text: library.memberNote(sphere.id, member.identityKey) ?? '');
      final text = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Private note'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Only you see this'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
          ],
        ),
      );
      if (text != null) await library.setMemberNote(sphere.id, member.identityKey, text);
      return;
    }
    if (action == 'badges') {
      await showBadgesDialog(context, sphere.id, member.identityKey,
          context.read<ContactService>().getContact(member.identityKey)?.displayName ?? 'this member');
      return;
    }
    if (action == 'suspend') {
      await showSuspendDialog(context, sphere.id, member.identityKey,
          context.read<ContactService>().getContact(member.identityKey)?.displayName ?? 'this member');
      return;
    }
    if (action == 'mute') {
      final library = context.read<LibraryService>();
      final wasMuted = library.isMemberMuted(sphere.id, member.identityKey);
      await library.toggleMuteMember(sphere.id, member.identityKey);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(wasMuted
                ? 'Unmuted here'
                : 'Muted in this sphere. They are not told, and nothing is deleted.')));
      }
      return;
    }
    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);

    try {
      if (action == 'promote') {
        await service.promote(sphere.id, member.identityKey);
      } else if (action == 'demote') {
        await service.demote(sphere.id, member.identityKey);
      } else if (action == 'transfer') {
        final confirmed = await _confirmTransfer(context, sphere, member);
        if (confirmed != true) return;
        await service.offerOwnership(sphere.id, member.identityKey);
        messenger.showSnackBar(const SnackBar(
          content: Text(
            'Offered. Nothing changes until they accept, and the offer '
            'lapses after a week.',
          ),
          duration: Duration(seconds: 4),
        ));
      } else if (action == 'propose') {
        await _proposeRemoval(context, sphere, member);
        return;
      } else if (action == 'remove') {
        await service.removeMember(sphere.id, member.identityKey);
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Removed. They keep what they already had, but cannot read '
              'anything posted from now on.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _showAddMember(BuildContext context, Sphere sphere) async {
    final contacts = context
        .read<ContactService>()
        .contacts
        .where((c) => !c.blocked && !sphere.contains(c.publicKey))
        .toList();

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Everyone you know is already in here')),
      );
      return;
    }

    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Add to sphere',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ...contacts.map((contact) => ListTile(
                  title: Text(contact.displayName),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    try {
                      await service.addMember(sphere.id, contact.publicKey);
                      messenger.showSnackBar(SnackBar(
                        content: Text(
                            '${contact.displayName} was invited and will be asked to join'),
                      ));
                    } catch (e) {
                      messenger
                          .showSnackBar(SnackBar(content: Text('Failed: $e')));
                    }
                  },
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _castVote(
    BuildContext context,
    String proposalId, {
    required bool inFavour,
  }) async {
    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await service.voteOnRemoval(proposalId, inFavour: inFavour);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _proposeRemoval(
    BuildContext context,
    Sphere sphere,
    SphereMember member,
  ) async {
    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);
    final reasonController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Put it to the sphere?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Everyone except you and them can vote, for 72 hours. It passes '
              'on a majority of those who vote, provided enough people do. '
              'The reason you give is shown to the whole sphere, including '
              'them.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              autofocus: true,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Propose')),
        ],
      ),
    );

    if (confirmed == true) {
      final reason = reasonController.text.trim();
      if (reason.isEmpty) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Give a reason — the sphere is being asked to decide'),
        ));
      } else {
        try {
          await service.proposeRemoval(sphere.id, member.identityKey, reason);
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
        }
      }
    }
    reasonController.dispose();
  }

  Future<bool?> _confirmTransfer(
    BuildContext context,
    Sphere sphere,
    SphereMember member,
  ) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Offer ownership?'),
          content: const Text(
            'They become the owner only once they accept, and you stay an '
            'admin. Ownership is what lets someone hand the sphere on, so '
            'offer it to someone who is still using the app.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Offer')),
          ],
        ),
      );

  Future<void> _acceptOwnership(BuildContext context, Sphere sphere) async {
    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await service.acceptOwnership(sphere.id);
      messenger.showSnackBar(
        SnackBar(content: Text('You now own "${sphere.name}"')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _showEditDetails(BuildContext context, Sphere sphere) async {
    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);
    final nameController = TextEditingController(text: sphere.name);
    final descriptionController =
        TextEditingController(text: sphere.description);

    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sphere details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descriptionController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'What this sphere is for',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (save == true) {
      try {
        await service.rename(
          sphere.id,
          name: nameController.text,
          description: descriptionController.text,
        );
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
    nameController.dispose();
    descriptionController.dispose();
  }

  Future<void> _confirmLeave(
    BuildContext context,
    Sphere sphere,
    String Function(String) nameFor,
  ) async {
    final service = context.read<SphereService>();
    final router = GoRouter.of(context);
    final me = context.read<IdentityService>().publicKey;

    final heir = (me != null && sphere.isOwner(me))
        ? sphere.successorAfter(me)
        : null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Leave "${sphere.name}"?'),
        content: Text(
          'Its keys are deleted from this device, so its content becomes '
          'unreadable here. This cannot be undone without being invited again.'
          '${heir == null ? '' : '\n\nYou own this sphere, so ${nameFor(heir)} '
              'becomes the owner when you go.'}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await service.leave(sphere.id);
    router.pop();
  }
}

/// Shown to the person who has been offered ownership.
///
/// The offer is only meaningful if they see it, and a sphere whose ownership
/// is in mid-air is exactly the state worth surfacing.
class _OwnershipOfferBanner extends StatelessWidget {
  final Sphere sphere;
  final String offeredBy;
  final VoidCallback onAccept;

  const _OwnershipOfferBanner({
    required this.sphere,
    required this.offeredBy,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.primaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$offeredBy has offered you ownership of this sphere.',
            style: TextStyle(
                color: cs.onPrimaryContainer, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'As owner you can hand the sphere on and decide who is an admin. '
            'The offer lapses if it is not accepted within a week.',
            style: TextStyle(color: cs.onPrimaryContainer, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: onAccept,
              child: const Text('Accept ownership'),
            ),
          ),
        ],
      ),
    );
  }
}

/// An open removal vote, shown to everyone in the sphere.
///
/// Deliberately not hidden from the person it concerns. There is nobody to
/// appeal to here, so the least a sphere can do is let someone see that they
/// are being discussed, and why.
class _RemovalVoteCard extends StatelessWidget {
  final SignedStatement proposal;
  final RemovalTally tally;
  final DateTime closesAt;
  final String subjectName;
  final String proposerName;
  final bool? myVote;
  final bool canVote;
  final void Function(bool inFavour) onVote;

  const _RemovalVoteCard({
    required this.proposal,
    required this.tally,
    required this.closesAt,
    required this.subjectName,
    required this.proposerName,
    required this.myVote,
    required this.canVote,
    required this.onVote,
  });

  String get _remaining {
    final left = closesAt.difference(DateTime.now());
    if (left.isNegative) return 'closing';
    if (left.inHours >= 1) return '${left.inHours}h left';
    return '${left.inMinutes}m left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      width: double.infinity,
      color: cs.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$proposerName proposed removing $subjectName',
            style: TextStyle(
                color: cs.onErrorContainer, fontWeight: FontWeight.w600),
          ),
          if (proposal.detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('“${proposal.detail}”',
                style: TextStyle(
                    color: cs.onErrorContainer, fontStyle: FontStyle.italic)),
          ],
          const SizedBox(height: 6),
          Text(
            '${tally.inFavour} for · ${tally.against} against · '
            '${tally.cast}/${tally.eligible} voted · $_remaining',
            style: TextStyle(color: cs.onErrorContainer, fontSize: 12),
          ),
          if (!tally.quorumMet)
            Text(
              'Needs ${tally.quorum} to vote for the result to count.',
              style: TextStyle(color: cs.onErrorContainer, fontSize: 12),
            ),
          const SizedBox(height: 8),
          if (canVote)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: myVote == false ? null : () => onVote(false),
                  child: Text(myVote == false ? 'Voted against' : 'Against'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: myVote == true ? null : () => onVote(true),
                  child: Text(myVote == true ? 'Voted for' : 'For removal'),
                ),
              ],
            )
          else
            Text(
              'You cannot vote on this one.',
              style: TextStyle(color: cs.onErrorContainer, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

/// One round tonal icon button in a sphere's header. The label is the
/// tooltip, read aloud by a screen reader and shown on a long press.
class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _HeaderAction({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: cs.surface.withValues(alpha: 0.7),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, color: cs.primary, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}
