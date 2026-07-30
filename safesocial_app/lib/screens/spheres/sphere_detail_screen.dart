import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/removal_vote.dart';
import '../../models/sphere.dart';
import '../../services/call_service.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_service.dart';

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
      return '${key.substring(0, 8)}…';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(sphere.name),
        actions: [
          if (sphere.members.length > 1)
            IconButton(
              icon: const Icon(Icons.videocam_outlined),
              tooltip: 'Start group call',
              onPressed: () => _startGroupCall(context, sphere),
            ),
          if (iAmAdmin)
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              tooltip: 'Add member',
              onPressed: () => _showAddMember(context, sphere),
            ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Activity',
            onPressed: () => context.push('/sphere/$sphereId/log'),
          ),
        ],
      ),
      body: ListView(
        children: [
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
          if (sphere.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(sphere.description, style: theme.textTheme.bodyMedium),
            ),
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
              leading: CircleAvatar(
                backgroundColor: cs.surfaceContainerHighest,
                child: Text(nameFor(member.identityKey).characters.first.toUpperCase()),
              ),
              title: Text(nameFor(member.identityKey)),
              subtitle: Text(_roleLabel(member.role)),
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
          if (iAmOwner && sphere.members.length == 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'You are the only member. Nobody else can re-key this sphere, '
                'so add someone and make them an admin before you rely on it.',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
              ),
            )
          else if (iAmOwner && sphere.admins.length == 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'You are the only admin. If you lose this device nobody can '
                'invite or remove anyone here again. Making a second admin '
                'costs nothing.',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
              ),
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
  Future<void> _startGroupCall(BuildContext context, Sphere sphere) async {
    final calls = context.read<CallService>();
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final type = await showDialog<CallType>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Call ${sphere.name}?'),
        content: Text(
          'Everyone in this sphere (${sphere.members.length - 1} other '
          '${sphere.members.length == 2 ? 'person' : 'people'}) will be rung.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, CallType.audio),
            child: const Text('Audio'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, CallType.video),
            child: const Text('Video'),
          ),
        ],
      ),
    );
    if (type == null) return;

    try {
      await calls.startGroupCall(
        sphere.id,
        sphere.members.map((m) => m.identityKey).toList(),
        type,
      );
      router.push('/call');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not start call: $e')));
    }
  }

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

    if (!canPromote &&
        !canDemoteThem &&
        !canStepDown &&
        !canRemove &&
        !canHandOver &&
        !canPropose) {
      return null;
    }

    return PopupMenuButton<String>(
      onSelected: (action) => _onMemberAction(context, sphere, member, action),
      itemBuilder: (_) => [
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

  Future<void> _onMemberAction(
    BuildContext context,
    Sphere sphere,
    SphereMember member,
    String action,
  ) async {
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
