import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/secure_store.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  group('message reactions and replies', () {
    Message message({
      List<MessageReaction> reactions = const [],
      String? replyTo,
    }) =>
        Message(
          id: 'm1',
          senderId: 'alice',
          recipientId: 'bob',
          content: 'hello',
          timestamp: DateTime(2026),
          reactions: reactions,
          replyToMessageId: replyTo,
        );

    test('reactions survive a round trip', () {
      final original = message(reactions: [
        MessageReaction(
            reactorId: 'bob', emoji: '👍', timestamp: DateTime(2026)),
      ]);

      final restored = Message.fromJson(original.toJson());

      expect(restored.reactions.single.emoji, '👍');
      expect(restored.reactions.single.reactorId, 'bob');
    });

    test('an empty reaction list is omitted from the wire', () {
      // Most messages carry none; sending an empty list on every one is waste.
      expect(message().toJson().containsKey('reactions'), isFalse);
    });

    test('a reply carries only the id of what it answers', () {
      final json = message(replyTo: 'm0').toJson();

      expect(json['replyToMessageId'], 'm0');
      // No copy of the quoted text: the recipient already has it, and copying
      // would let a deleted message live on inside a reply.
      expect(json.keys, isNot(contains('replyToContent')));
    });

    test('messages from before these fields decode cleanly', () {
      final legacy = message().toJson()
        ..remove('replyToMessageId')
        ..remove('reactions');

      final restored = Message.fromJson(legacy);
      expect(restored.replyToMessageId, isNull);
      expect(restored.reactions, isEmpty);
    });

    test('reactions participate in equality so the UI rebuilds', () {
      expect(
        message(reactions: [
          MessageReaction(
              reactorId: 'bob', emoji: '👍', timestamp: DateTime(2026))
        ]),
        isNot(equals(message())),
      );
    });
  });

  group('saves', () {
    test('saving and unsaving', () async {
      final library = LibraryService();

      expect(library.isSaved('p1'), isFalse);
      await library.toggleSave('p1');
      expect(library.isSaved('p1'), isTrue);
      await library.toggleSave('p1');
      expect(library.isSaved('p1'), isFalse);
    });

    test('the default collection always exists', () {
      expect(LibraryService().collectionNames,
          contains(LibraryService.defaultCollection));
    });

    test('collections can be created but the default cannot be deleted', () async {
      final library = LibraryService();
      await library.createCollection('Recipes');
      await library.toggleSave('p1', collection: 'Recipes');

      expect(library.postsIn('Recipes'), ['p1']);

      await library.deleteCollection(LibraryService.defaultCollection);
      expect(library.collectionNames,
          contains(LibraryService.defaultCollection));
    });

    test('unsaving removes a post from every collection', () async {
      final library = LibraryService();
      await library.createCollection('Recipes');
      await library.toggleSave('p1', collection: 'Recipes');
      await library.toggleSave('p1');

      // Otherwise the toggle is confusing: it would still read as saved.
      expect(library.isSaved('p1'), isFalse);
      expect(library.postsIn('Recipes'), isEmpty);
    });

    test('pruning drops saves whose posts are gone', () async {
      final library = LibraryService();
      await library.toggleSave('p1');
      await library.toggleSave('p2');

      await library.pruneMissing({'p2'});

      expect(library.allSavedPostIds, {'p2'});
    });

    test('saves survive a restart', () async {
      await LibraryService().toggleSave('p1');

      final restored = LibraryService();
      await restored.load();

      expect(restored.isSaved('p1'), isTrue);
    });

    test('saves are stored encrypted', () async {
      await LibraryService().toggleSave('secret-post-id');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('spheres_saved_v1');
      expect(raw, isNotNull);
      expect(raw, isNot(contains('secret-post-id')));
    });
  });

  group('muting and pinning', () {
    test('muting a sphere toggles and persists', () async {
      final library = LibraryService();
      await library.toggleMute('sphere-1');
      expect(library.isMuted('sphere-1'), isTrue);

      final restored = LibraryService();
      await restored.load();
      expect(restored.isMuted('sphere-1'), isTrue);
    });

    test('pinned chats sort to the top, keeping pin order', () async {
      final library = LibraryService();
      await library.togglePin('bob');
      await library.togglePin('carol');

      // Most recently pinned first, then everything else untouched.
      expect(library.sortChats(['alice', 'bob', 'carol']),
          ['carol', 'bob', 'alice']);
    });

    test('unpinning restores the original order', () async {
      final library = LibraryService();
      await library.togglePin('carol');
      await library.togglePin('carol');

      expect(library.sortChats(['alice', 'bob', 'carol']),
          ['alice', 'bob', 'carol']);
    });

    test('a pin for a chat that no longer exists is ignored', () async {
      final library = LibraryService();
      await library.togglePin('deleted-contact');

      expect(library.sortChats(['alice']), ['alice']);
    });
  });

  test('collections are persisted as encrypted JSON, not plaintext', () async {
    final library = LibraryService();
    await library.createCollection('Holiday');
    await library.toggleSave('p1', collection: 'Holiday');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('spheres_saved_v1')!;
    expect(raw, startsWith('enc1:'));

    // And it really does decode back to the same structure.
    final restored = LibraryService();
    await restored.load();
    expect(jsonEncode(restored.postsIn('Holiday')), jsonEncode(['p1']));
  });
}
