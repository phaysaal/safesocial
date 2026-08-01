import 'post.dart';

/// A comment, and whether it answers another one.
class ThreadedComment {
  final Comment comment;

  /// True when this is a reply, and should be indented under what it answers.
  final bool isReply;

  const ThreadedComment(this.comment, this.isReply);
}

/// Put every reply directly beneath the comment it answers.
///
/// Comments were rendered in the order they happened to be received, so a
/// reply could sit well away from the thing it replied to, or above it — the
/// relay promises no ordering and the list was never rearranged.
///
/// Arranged for display rather than at storage time, so arrival order is left
/// alone and the same stored data can be presented differently later.
///
/// Only one level of indentation. A reply to a reply stays at the same depth,
/// as in most apps: nesting further turns a conversation into a staircase and
/// eventually runs out of screen.
List<ThreadedComment> threadComments(List<Comment> comments) {
  final byTime = [...comments]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  final ids = byTime.map((c) => c.id).toSet();
  final replies = <String, List<Comment>>{};
  final roots = <Comment>[];

  for (final comment in byTime) {
    final parent = comment.replyToId;
    // A reply whose parent never arrived, or was removed, is shown as a
    // comment of its own. Misplacing it is better than hiding it.
    if (parent == null || parent == comment.id || !ids.contains(parent)) {
      roots.add(comment);
    } else {
      replies.putIfAbsent(parent, () => []).add(comment);
    }
  }

  final ordered = <ThreadedComment>[];
  final seen = <String>{};

  void emit(Comment comment, bool isReply) {
    // Guards against a cycle in replyToId, which nothing on the wire prevents.
    if (!seen.add(comment.id)) return;
    ordered.add(ThreadedComment(comment, isReply));
    for (final reply in replies[comment.id] ?? const <Comment>[]) {
      emit(reply, true);
    }
  }

  for (final root in roots) {
    emit(root, false);
  }

  // Anything left out by a cycle still deserves to be shown.
  for (final comment in byTime) {
    if (seen.add(comment.id)) ordered.add(ThreadedComment(comment, true));
  }
  return ordered;
}
