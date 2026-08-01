import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/post.dart';

/// One post can go to several spheres. It cannot be *sent* once, because each
/// sphere has its own key — so one envelope is sealed per sphere, all carrying
/// the same post id, and the reader unions them back into a single post.
///
/// The property that matters is what each copy does *not* say: an envelope
/// names only the sphere it is addressed to, so a reader ends up knowing
/// exactly the spheres they are already in and nothing more. Someone in Family
/// cannot tell the post also went to Work. That falls out of sealing per
/// sphere rather than being a rule anybody has to remember to enforce.
void main() {
  Post post({
    String id = 'p1',
    required String sphereId,
    Set<String>? sphereIds,
  }) =>
      Post(
        id: id,
        authorId: 'alice',
        authorName: 'Alice',
        content: 'hello',
        createdAt: DateTime(2026, 8, 1),
        sphereId: sphereId,
        sphereIds: sphereIds,
      );

  test('a post addressed to one sphere belongs to exactly that one', () {
    expect(post(sphereId: 'family').sphereIds, {'family'});
  });

  test('a post can name several spheres', () {
    final shared = post(sphereId: 'family', sphereIds: {'family', 'work'});

    expect(shared.sphereIds, {'family', 'work'});
  });

  group('what travels', () {
    test('a copy for one sphere mentions only that sphere', () {
      // The whole privacy argument in one assertion.
      final copy = post(sphereId: 'family', sphereIds: {'family', 'work'})
          .copyWith(sphereId: 'family', sphereIds: {'family'});

      final wire = jsonEncode(copy.toJson());

      expect(wire, contains('family'));
      expect(wire, isNot(contains('work')));
    });

    test('a single-sphere post carries no list at all', () {
      // Nothing to say, so nothing is said.
      expect(post(sphereId: 'family').toJson().containsKey('sphereIds'),
          isFalse);
    });

    test('a copy decodes as belonging to its own sphere', () {
      final decoded = Post.fromJson(
          jsonDecode(jsonEncode(post(sphereId: 'work').toJson()))
              as Map<String, dynamic>);

      expect(decoded.sphereIds, {'work'});
    });
  });

  group('merging copies', () {
    test('a reader in both spheres ends up with one post in both', () {
      // What FeedService does when the second copy arrives: same id, union the
      // spheres rather than storing it twice.
      final first = post(sphereId: 'family');
      final second = post(sphereId: 'work');

      final merged = first
          .copyWith(sphereIds: {...first.sphereIds, ...second.sphereIds});

      expect(merged.id, second.id);
      expect(merged.sphereIds, {'family', 'work'});
    });

    test('a reader in one sphere only ever learns about that one', () {
      // They never receive the other copy, so there is nothing to union.
      final onlyCopyTheyGet = post(sphereId: 'family');

      expect(onlyCopyTheyGet.sphereIds, {'family'});
    });

    test('the same copy twice changes nothing', () {
      final first = post(sphereId: 'family');
      final again = post(sphereId: 'family');

      final merged =
          first.copyWith(sphereIds: {...first.sphereIds, ...again.sphereIds});

      expect(merged.sphereIds, {'family'});
    });
  });

  test('the sphere set survives being written out and read back', () {
    // Storage keeps the merged view; only what goes on the wire is trimmed.
    final shared = post(sphereId: 'family', sphereIds: {'family', 'work'});

    final restored = Post.fromJson(
        jsonDecode(jsonEncode(shared.toJson())) as Map<String, dynamic>);

    expect(restored.sphereIds, {'family', 'work'});
  });

  test('a post saved before this existed still reads', () {
    final legacy = {
      'id': 'p1',
      'authorId': 'alice',
      'authorName': 'Alice',
      'content': 'hello',
      'createdAt': DateTime(2026).toIso8601String(),
      'sphereId': 'family',
    };

    expect(Post.fromJson(legacy).sphereIds, {'family'});
  });
}
