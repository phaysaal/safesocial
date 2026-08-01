import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/comment_thread.dart';
import 'package:spheres_app/models/post.dart';

/// Comments were rendered in whatever order they arrived, so a reply could sit
/// well away from the thing it answered, or above it — the relay promises no
/// ordering and the list was never rearranged.
void main() {
  Comment comment(
    String id, {
    String? replyTo,
    int minute = 0,
    String author = 'alice',
  }) =>
      Comment(
        id: id,
        authorId: author,
        authorName: 'Alice',
        text: id,
        createdAt: DateTime(2026, 8, 1, 12, minute),
        replyToId: replyTo,
      );

  List<String> order(List<Comment> comments) =>
      threadComments(comments).map((t) => t.comment.id).toList();

  test('comments with no replies stay in time order', () {
    final threaded = threadComments([
      comment('b', minute: 2),
      comment('a', minute: 1),
    ]);

    expect(threaded.map((t) => t.comment.id), ['a', 'b']);
    expect(threaded.every((t) => !t.isReply), isTrue);
  });

  test('a reply sits directly under what it answers', () {
    // Even when it arrived last and its parent was written first.
    expect(
      order([
        comment('first', minute: 1),
        comment('second', minute: 2),
        comment('reply-to-first', replyTo: 'first', minute: 3),
      ]),
      ['first', 'reply-to-first', 'second'],
    );
  });

  test('a reply that arrived before its parent is still placed under it', () {
    expect(
      order([
        comment('reply', replyTo: 'parent', minute: 1),
        comment('parent', minute: 2),
      ]),
      ['parent', 'reply'],
    );
  });

  test('replies to one comment keep their own order', () {
    expect(
      order([
        comment('parent', minute: 1),
        comment('r2', replyTo: 'parent', minute: 3),
        comment('r1', replyTo: 'parent', minute: 2),
      ]),
      ['parent', 'r1', 'r2'],
    );
  });

  test('only replies are marked for indentation', () {
    final threaded = threadComments([
      comment('parent', minute: 1),
      comment('reply', replyTo: 'parent', minute: 2),
    ]);

    expect(threaded.first.isReply, isFalse);
    expect(threaded.last.isReply, isTrue);
  });

  test('a reply to a reply does not indent further', () {
    // One level only: nesting deeper turns a conversation into a staircase.
    final threaded = threadComments([
      comment('parent', minute: 1),
      comment('reply', replyTo: 'parent', minute: 2),
      comment('deep', replyTo: 'reply', minute: 3),
    ]);

    expect(threaded.map((t) => t.comment.id), ['parent', 'reply', 'deep']);
    expect(threaded.map((t) => t.isReply), [false, true, true]);
  });

  test('a reply whose parent never arrived is still shown', () {
    // Losing it would be worse than misplacing it.
    expect(order([comment('orphan', replyTo: 'gone', minute: 1)]), ['orphan']);
  });

  test('a comment replying to itself does not disappear', () {
    expect(order([comment('self', replyTo: 'self')]), ['self']);
  });

  test('a cycle cannot hide comments or hang', () {
    // Nothing on the wire stops a peer sending one.
    final result = order([
      comment('a', replyTo: 'b', minute: 1),
      comment('b', replyTo: 'a', minute: 2),
    ]);

    expect(result.toSet(), {'a', 'b'});
    expect(result, hasLength(2));
  });

  test('an empty list threads to nothing', () {
    expect(threadComments(const []), isEmpty);
  });
}
