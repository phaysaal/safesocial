import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/post.dart';

/// View receipts are a disclosure — they tell someone you looked. These pin
/// the shape of that on the model: a viewer is recorded once, and the list
/// only ever lives on the author's copy.
void main() {
  Post story({List<String> viewedBy = const []}) => Post(
        id: 'story-1',
        authorId: 'author',
        authorName: 'Author',
        content: '',
        createdAt: DateTime(2026, 5, 1),
        sphereId: 'sphere-1',
        isStory: true,
        expiresAt: DateTime(2026, 5, 2),
        viewedBy: viewedBy,
      );

  test('a story starts with no viewers', () {
    expect(story().viewedBy, isEmpty);
  });

  test('viewers survive a JSON round trip', () {
    final restored = Post.fromJson(story(viewedBy: ['bob', 'carol']).toJson());

    expect(restored.viewedBy, ['bob', 'carol']);
  });

  test('a post written before view receipts existed decodes cleanly', () {
    final legacy = story().toJson()..remove('viewedBy');

    expect(Post.fromJson(legacy).viewedBy, isEmpty);
  });

  test('copyWith replaces the viewer list', () {
    expect(story().copyWith(viewedBy: ['bob']).viewedBy, ['bob']);
  });

  test('viewers are part of equality, so the UI rebuilds on a new view', () {
    expect(story(viewedBy: ['bob']), isNot(equals(story())));
    expect(story(viewedBy: ['bob']), equals(story(viewedBy: ['bob'])));
  });
}
