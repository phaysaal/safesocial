import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/message.dart';

/// A story reply is a private message to the author carrying the story's id,
/// not a comment the sphere can see and not a copy of the story's content.
void main() {
  Message reply({String? storyId}) => Message(
        id: 'm1',
        senderId: 'bob',
        recipientId: 'alice',
        content: 'nice photo',
        timestamp: DateTime(2026, 5, 1),
        replyToStoryId: storyId,
      );

  test('an ordinary message has no story reference', () {
    expect(reply().replyToStoryId, isNull);
  });

  test('the story id survives a round trip', () {
    final restored = Message.fromJson(reply(storyId: 'story-1').toJson());

    expect(restored.replyToStoryId, 'story-1');
    expect(restored.content, 'nice photo');
  });

  test('the field is omitted from the wire when unset', () {
    // Keeps ordinary messages from carrying a null key on every send.
    expect(reply().toJson().containsKey('replyToStoryId'), isFalse);
  });

  test('a message from before story replies decodes cleanly', () {
    final legacy = reply(storyId: 'story-1').toJson()..remove('replyToStoryId');

    expect(Message.fromJson(legacy).replyToStoryId, isNull);
  });

  test('the reply carries no copy of the story content', () {
    // Stories expire; a reply must not resurrect what was meant to disappear.
    final json = reply(storyId: 'story-1').toJson();

    expect(json.keys, isNot(contains('storyContent')));
    expect(json.keys, isNot(contains('storyPreview')));
    expect(json['replyToStoryId'], 'story-1');
  });

  test('the story reference participates in equality', () {
    expect(reply(storyId: 'story-1'), isNot(equals(reply())));
    expect(reply(storyId: 'story-1'), equals(reply(storyId: 'story-1')));
  });

  test('copyWith preserves the story reference', () {
    final edited = reply(storyId: 'story-1').copyWith(delivered: true);

    expect(edited.replyToStoryId, 'story-1');
    expect(edited.delivered, isTrue);
  });
}
