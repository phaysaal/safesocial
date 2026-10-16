import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/comment_thread.dart';
import 'package:spheres_app/models/post.dart';

/// Comments grew edits, reactions, hiding and pinning. What matters: a
/// comment written before any of that still reads, a comment that has none
/// of it still writes the same bytes as before, and the thread helper puts
/// pinned ones first and can run newest-first without breaking replies.
void main() {
  Comment comment(String id, DateTime at,
          {String? replyTo, bool pinned = false, bool hidden = false}) =>
      Comment(
        id: id,
        authorId: 'a',
        text: id,
        createdAt: at,
        replyToId: replyTo,
        pinned: pinned,
        hidden: hidden,
      );

  test('a comment saved before edits and reactions existed still reads', () {
    final old = {
      'id': 'c1',
      'authorId': 'alice',
      'authorName': 'Alice',
      'text': 'hi',
      'createdAt': '2026-10-11T10:00:00.000',
      'replyToId': null,
    };
    final c = Comment.fromJson(old);
    expect(c.isEdited, isFalse);
    expect(c.history, isEmpty);
    expect(c.reactions, isEmpty);
    expect(c.hidden, isFalse);
    expect(c.pinned, isFalse);
  });

  test('a plain comment writes nothing new, so old readers are not confused', () {
    final c = Comment(
        id: 'c1', authorId: 'alice', text: 'hi', createdAt: DateTime(2026));
    final keys = c.toJson().keys.toSet();
    expect(keys, {'id', 'authorId', 'authorName', 'text', 'createdAt', 'replyToId'});
  });

  test('edits, reactions, hidden and pinned survive a round trip', () {
    final c = Comment(
      id: 'c1',
      authorId: 'alice',
      text: 'now',
      createdAt: DateTime(2026, 1, 1),
      editedAt: DateTime(2026, 1, 2),
      history: const ['before', 'then'],
      reactions: [
        Reaction(reactorId: 'bob', emoji: '❤️', timestamp: DateTime(2026, 1, 3))
      ],
      hidden: true,
      pinned: true,
    );
    final back =
        Comment.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
    expect(back, c);
    expect(back.hasReactionFrom('bob', '❤️'), isTrue);
    expect(back.hasReactionFrom('bob', '👍'), isFalse);
  });

  test('garbage in the new fields is ignored rather than thrown', () {
    final c = Comment.fromJson({
      'id': 'c1',
      'authorId': 'a',
      'text': 't',
      'createdAt': '2026-10-11T10:00:00.000',
      'editedAt': 42,
      'history': ['ok', 7, null],
      'reactions': ['not a map', 3],
      'hidden': 'yes',
      'pinned': 1,
    });
    expect(c.editedAt, isNull);
    expect(c.history, ['ok']);
    expect(c.reactions, isEmpty);
    expect(c.hidden, isFalse);
    expect(c.pinned, isFalse);
  });

  test('a post with comments off says so only when it is', () {
    final open = Post(
        id: 'p', authorId: 'a', content: '', createdAt: DateTime(2026), sphereId: 's');
    expect(open.toJson().containsKey('commentsOff'), isFalse);
    final closed = open.copyWith(commentsOff: true);
    expect(Post.fromJson(closed.toJson()).commentsOff, isTrue);
  });

  test('hidden comments are shown to their author and to moderators only', () {
    final post = Post(
      id: 'p',
      authorId: 'owner',
      content: '',
      createdAt: DateTime(2026),
      sphereId: 's',
      comments: [
        comment('shown', DateTime(2026, 1, 1)),
        Comment(
            id: 'hid', authorId: 'troll', text: 'x', createdAt: DateTime(2026, 1, 2), hidden: true),
      ],
    );
    expect(post.visibleComments('someone').map((c) => c.id), ['shown']);
    expect(post.visibleComments('troll').map((c) => c.id), ['shown', 'hid']);
    expect(post.visibleComments('owner', moderator: true).map((c) => c.id),
        ['shown', 'hid']);
  });

  group('threading', () {
    final t0 = DateTime(2026, 1, 1);
    final comments = [
      comment('first', t0),
      comment('reply-to-first', t0.add(const Duration(minutes: 5)), replyTo: 'first'),
      comment('second', t0.add(const Duration(minutes: 1))),
      comment('third-pinned', t0.add(const Duration(minutes: 2)), pinned: true),
    ];

    test('pinned comments lead, then the rest in time order with replies beneath',
        () {
      final ids = threadComments(comments).map((t) => t.comment.id).toList();
      expect(ids, ['third-pinned', 'first', 'reply-to-first', 'second']);
    });

    test('newest first reverses the top level and keeps replies under their parent',
        () {
      final ordered = threadComments(comments, newestFirst: true);
      expect(ordered.map((t) => t.comment.id).toList(),
          ['third-pinned', 'second', 'first', 'reply-to-first']);
      expect(ordered.last.isReply, isTrue);
    });
  });

  test('reaction kinds are one shared list, with no thumb and no "Like" on offer', () {
    expect(ReactionKinds.all.length, 8);
    expect(ReactionKinds.all.map((k) => k.$2), isNot(contains('Like')));
    expect(ReactionKinds.all.map((k) => k.$1), isNot(contains('👍')));
    expect(ReactionKinds.all, contains(ReactionKinds.primary));
    expect(ReactionKinds.contains('🙅'), isTrue);
    expect(ReactionKinds.labelFor('🙅'), 'Not for me');
    expect(ReactionKinds.contains('🍕'), isFalse);
    final tally = ReactionKinds.tally([
      Reaction(reactorId: 'a', emoji: '🙌', timestamp: DateTime(2026)),
      Reaction(reactorId: 'b', emoji: '😂', timestamp: DateTime(2026)),
      Reaction(reactorId: 'c', emoji: '😂', timestamp: DateTime(2026)),
    ]);
    expect(tally.keys.first, '😂');
    expect(tally['🙌'], 1);
  });

  test('a reaction from before the set changed is still accepted and still named', () {
    // A thumb left in September, or sent by a client not yet updated, keeps
    // its meaning; it is only no longer offered.
    for (final old in ['👍', '❤️', '🤗', '✅', '❌']) {
      expect(ReactionKinds.contains(old), isTrue, reason: old);
    }
    expect(ReactionKinds.labelFor('👍'), 'Like');
    expect(ReactionKinds.labelFor('✅'), 'Agree');
  });
}
