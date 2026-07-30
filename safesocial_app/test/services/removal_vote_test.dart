import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/removal_vote.dart';
import 'package:spheres_app/models/sphere.dart';

/// The arithmetic of removing somebody by vote.
///
/// Removal is the only decision here that is irreversible for the person on
/// the receiving end, and there is no authority to appeal to afterwards. These
/// are the rules that make it legitimate rather than merely possible.
void main() {
  RemovalTally tally({
    required int eligible,
    int yes = 0,
    int no = 0,
    bool open = true,
  }) =>
      RemovalTally(
          eligible: eligible, inFavour: yes, against: no, withinWindow: open);

  group('quorum', () {
    test('is a third of those eligible, rounded up', () {
      expect(tally(eligible: 9).quorum, 3);
      expect(tally(eligible: 10).quorum, 4);
      expect(tally(eligible: 11).quorum, 4);
      expect(tally(eligible: 12).quorum, 4);
    });

    test('is at least one, so nothing passes on no votes at all', () {
      expect(tally(eligible: 1).quorum, 1);
      expect(tally(eligible: 2).quorum, 1);
    });

    test('in a small sphere a single voter can decide — by design', () {
      // A third of two is one. Worth stating outright rather than leaving as
      // an accident of the arithmetic: in a sphere of four, one person voting
      // yes while nobody else bothers is enough. The alternative — demanding
      // more from a group this size — is a rule that deadlocks instead, and
      // anyone uncomfortable with the outcome can leave.
      final t = tally(eligible: 2, yes: 1, open: false);
      expect(t.quorumMet, isTrue);
      expect(t.outcome, RemovalOutcome.passed);
    });

    test('three people cannot remove someone from a sphere of fifty', () {
      // The reason a threshold alone is not enough.
      final t = tally(eligible: 48, yes: 3, open: false);
      expect(t.quorumMet, isFalse);
      expect(t.outcome, RemovalOutcome.expiredWithoutQuorum);
    });

    test('silence is not consent', () {
      // Nobody voted; the window closed. That is not agreement.
      expect(tally(eligible: 10, open: false).outcome,
          RemovalOutcome.expiredWithoutQuorum);
    });
  });

  group('majority', () {
    test('a tie fails', () {
      // Removing somebody should need more than the absence of disagreement.
      final t = tally(eligible: 6, yes: 2, no: 2, open: false);
      expect(t.quorumMet, isTrue);
      expect(t.outcome, RemovalOutcome.rejected);
    });

    test('a majority of those who voted carries it', () {
      expect(tally(eligible: 6, yes: 3, no: 1, open: false).outcome,
          RemovalOutcome.passed);
    });

    test('more against than for is a rejection, not an expiry', () {
      // The sphere deserves to know it was considered and refused.
      expect(tally(eligible: 6, yes: 1, no: 3, open: false).outcome,
          RemovalOutcome.rejected);
    });
  });

  group('the window', () {
    test('an undecided vote stays open', () {
      expect(tally(eligible: 6, yes: 2, no: 1).outcome, RemovalOutcome.open);
    });

    test('a vote the remainder cannot overturn closes early', () {
      // 5 eligible, 4 in favour, 0 against: the last voter cannot change it.
      final t = tally(eligible: 5, yes: 4);
      expect(t.outcome, RemovalOutcome.passed);
    });

    test('a vote the remainder could still overturn does not close early', () {
      // 5 eligible, 2 for, 1 against — the two who have not voted could tie it.
      expect(tally(eligible: 5, yes: 2, no: 1).outcome, RemovalOutcome.open);
    });
  });

  group('how many more are needed', () {
    test('is zero once it has passed', () {
      expect(tally(eligible: 5, yes: 4).stillNeeded, 0);
    });

    test('counts what it takes to reach quorum', () {
      expect(tally(eligible: 9, yes: 1).stillNeeded, 2);
    });

    test('counts what it takes to overtake the opposition', () {
      expect(tally(eligible: 9, yes: 1, no: 4).stillNeeded, 4);
    });
  });

  group('who may be proposed', () {
    final alice = 'a' * 64;
    final bob = 'b' * 64;
    final carol = 'c' * 64;
    final dave = 'd' * 64;

    SphereMember member(String key, SphereRole role) => SphereMember(
        identityKey: key, role: role, joinedAt: DateTime(2026), invitedBy: alice);

    Sphere sphere(List<SphereMember> members) => Sphere(
          id: 'x' * 64,
          name: 'Family',
          kind: SphereKind.group,
          createdBy: alice,
          createdAt: DateTime(2026),
          epoch: 1,
          members: members,
        );

    final full = sphere([
      member(alice, SphereRole.owner),
      member(bob, SphereRole.member),
      member(carol, SphereRole.member),
    ]);

    test('a member may propose removing another member', () {
      expect(
        removalProposalRefusal(sphere: full, proposer: bob, subject: carol),
        isNull,
      );
    });

    test('the owner cannot be voted out', () {
      // They can hand the sphere on or leave; either way it passes on. Being
      // able to vote out the owner would just be a coup with extra steps.
      expect(
        removalProposalRefusal(sphere: full, proposer: bob, subject: alice),
        contains('owner'),
      );
    });

    test('you cannot propose removing yourself', () {
      expect(
        removalProposalRefusal(sphere: full, proposer: bob, subject: bob),
        contains('leave'),
      );
    });

    test('a stranger cannot propose anything', () {
      expect(
        removalProposalRefusal(sphere: full, proposer: dave, subject: bob),
        contains('not a member'),
      );
    });

    test('someone who already left cannot be proposed', () {
      expect(
        removalProposalRefusal(sphere: full, proposer: bob, subject: dave),
        contains('not a member'),
      );
    });

    test('a sphere of two cannot hold a vote', () {
      // Nobody is left to cast one, so it would be one person removing
      // another while calling it a decision.
      final pair = sphere([
        member(alice, SphereRole.owner),
        member(bob, SphereRole.member),
      ]);

      expect(
        removalProposalRefusal(sphere: pair, proposer: bob, subject: alice),
        isNotNull,
      );
    });

    test('in a sphere of three, one vote is quorum and carries', () {
      // The smallest sphere where voting means anything: Bob proposes, Carol
      // is the only eligible voter, and her single yes decides it.
      expect(
        removalProposalRefusal(sphere: full, proposer: bob, subject: carol),
        isNull,
      );
      final t = tally(eligible: 1, yes: 1);
      expect(t.quorum, 1);
      expect(t.outcome, RemovalOutcome.passed);
    });
  });
}
