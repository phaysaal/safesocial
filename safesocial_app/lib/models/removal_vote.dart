import 'sphere.dart';

/// Where a removal proposal stands.
enum RemovalOutcome {
  /// Still collecting votes.
  open,

  /// Enough people voted, and enough of them agreed.
  passed,

  /// The window closed without a majority.
  rejected,

  /// The window closed without enough people voting at all.
  ///
  /// Distinct from [rejected] on purpose. Silence is not consent, but it is
  /// not opposition either, and a sphere deserves to be told which happened.
  expiredWithoutQuorum,
}

/// The arithmetic of a removal vote, kept apart from transport and storage so
/// the rules can be read — and tested — in one place.
///
/// Removal is the one power that most needs legitimacy: it is the only
/// decision that is irreversible for the person on the receiving end, and
/// there is no authority to appeal to afterwards. So the rules are deliberately
/// conservative — a majority of those who vote, but only if enough of the
/// sphere turns out at all.
class RemovalTally {
  /// Members entitled to vote: everyone except the proposer and the subject.
  ///
  /// The proposer is excluded because proposing already expresses their view,
  /// and counting it twice would let a proposer in a small sphere carry a vote
  /// alone. The subject is excluded because a vote they could block is not a
  /// vote — a sphere of two would deadlock forever.
  final int eligible;

  final int inFavour;
  final int against;

  /// Whether voting is still open on the clock.
  final bool withinWindow;

  const RemovalTally({
    required this.eligible,
    required this.inFavour,
    required this.against,
    required this.withinWindow,
  });

  int get cast => inFavour + against;

  /// How many must vote for the result to count.
  ///
  /// A third of those eligible, rounded up, and never fewer than one. Without
  /// a quorum, three people in a sphere of fifty could remove someone while
  /// nobody else even knew it was happening.
  int get quorum => eligible == 0 ? 0 : ((eligible + 2) ~/ 3);

  bool get quorumMet => cast >= quorum && quorum > 0;

  /// A simple majority of those who actually voted. A tie fails: removing
  /// somebody should need more than the absence of disagreement.
  bool get majority => inFavour > against;

  RemovalOutcome get outcome {
    if (quorumMet && majority && !withinWindow) return RemovalOutcome.passed;
    // A decided vote need not wait out the clock: once enough people have
    // voted that the remainder cannot change the result, it is over.
    if (quorumMet && majority && _undecidable) return RemovalOutcome.passed;
    if (withinWindow) return RemovalOutcome.open;
    if (!quorumMet) return RemovalOutcome.expiredWithoutQuorum;
    return RemovalOutcome.rejected;
  }

  /// True when the votes still outstanding could not overturn the result.
  bool get _undecidable => inFavour - against > eligible - cast;

  bool get hasPassed => outcome == RemovalOutcome.passed;

  /// How many more yes votes would carry it right now, or zero if it already
  /// has. Shown in the UI so a vote in progress is legible.
  int get stillNeeded {
    if (hasPassed) return 0;
    // Enough to clear both the quorum and the majority.
    final forQuorum = quorum - cast;
    final forMajority = against - inFavour + 1;
    final needed = forQuorum > forMajority ? forQuorum : forMajority;
    return needed < 1 ? 1 : needed;
  }
}

/// Who may be proposed for removal, and by whom.
///
/// Returns null when the proposal is allowed, or a human-readable reason it is
/// not. Kept as a pure function so both the proposer's device and every
/// recipient apply exactly the same rule.
String? removalProposalRefusal({
  required Sphere sphere,
  required String proposer,
  required String subject,
}) {
  if (!sphere.contains(proposer)) return 'You are not a member of this sphere';
  if (!sphere.contains(subject)) return 'They are not a member of this sphere';
  if (proposer == subject) return 'To remove yourself, just leave';
  if (sphere.isOwner(subject)) {
    return 'The owner cannot be voted out. They can hand the sphere on or '
        'leave, and either way ownership passes on.';
  }
  if (sphere.members.length < 3) {
    // With two people there is nobody left to vote, so a "vote" would just be
    // one person removing another while calling it a decision.
    return 'A vote needs somebody to cast it. In a sphere this small, leaving '
        'is the honest option.';
  }
  return null;
}
