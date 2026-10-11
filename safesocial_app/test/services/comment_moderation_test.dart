import 'dart:async';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/inbound_events.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Who may do what to a comment, decided by who signed the envelope.
///
/// The signer is the only thing the receiver trusts: a payload can claim any
/// author, any "hidden" flag, any reaction. These tests feed the receive
/// path verified items with a stated signer and check that the rules hold:
/// only the author edits, the post's author or an admin hides and pins,
/// anyone deletes their own, a closed post takes no more comments.
void main() {
  late String alice, aliceSecret, bob, carol;
  late SphereService spheres;
  late FeedService feed;
  late Sphere sphere;

  String key(ed.KeyPair k) => hex.encode(k.publicKey.bytes);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    alice = key(a);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = key(ed.generateKey());
    carol = key(ed.generateKey());

    spheres = SphereService();
    spheres.configure(
      sessions: SessionManager(),
      identityKey: alice,
      identitySecret: aliceSecret,
      resolveExchangeKey: (_) => null,
    );
    // Alice owns the sphere, so she is its admin; Bob and Carol are members.
    sphere = await spheres.create(
        name: 'Family', kind: SphereKind.group, initialMembers: [bob, carol]);

    feed = FeedService();
    feed.initSync(alice, aliceSecret, const []);
    feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
  });

  Future<void> arrives(String signer, Map<String, dynamic> json) =>
      feed.applyFeedJson(authorId: signer, sphereId: sphere.id, json: json);

  Post post(String author, {bool commentsOff = false}) => Post(
        id: 'p1',
        authorId: author,
        content: 'hello',
        createdAt: DateTime(2026, 10, 11),
        sphereId: sphere.id,
        commentsOff: commentsOff,
      );

  Map<String, dynamic> commentFrom(String author, String id, {String? replyTo}) => {
        'type': 'comment',
        'post_id': 'p1',
        'comment': Comment(
          id: id,
          authorId: author,
          text: 'c $id',
          createdAt: DateTime(2026, 10, 11, 12),
          replyToId: replyTo,
        ).toJson(),
      };

  Post current() => feed.posts.singleWhere((p) => p.id == 'p1');

  test('only the comment\'s author may edit it, and the old text is kept', () async {
    await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
    await arrives(carol, commentFrom(carol, 'c1'));

    await arrives(bob, {
      'type': 'comment_edit', 'post_id': 'p1', 'comment_id': 'c1', 'text': 'forged'
    });
    expect(current().comments.single.text, 'c c1', reason: 'Bob is not the author');

    await arrives(carol, {
      'type': 'comment_edit', 'post_id': 'p1', 'comment_id': 'c1', 'text': 'fixed',
      'edited_at': '2026-10-11T13:00:00.000',
    });
    final edited = current().comments.single;
    expect(edited.text, 'fixed');
    expect(edited.history, ['c c1']);
    expect(edited.isEdited, isTrue);
  });

  test('hiding and pinning take the post\'s author or an admin; a flag in the comment itself is ignored',
      () async {
    await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
    final claimed = commentFrom(carol, 'c1');
    (claimed['comment'] as Map<String, dynamic>)['pinned'] = true;
    (claimed['comment'] as Map<String, dynamic>)['hidden'] = true;
    await arrives(carol, claimed);
    expect(current().comments.single.pinned, isFalse);
    expect(current().comments.single.hidden, isFalse);

    // Carol, a plain member who is not the post's author: refused.
    await arrives(carol, {
      'type': 'comment_hide', 'post_id': 'p1', 'comment_id': 'c1', 'hidden': true
    });
    expect(current().comments.single.hidden, isFalse);

    // Bob wrote the post: allowed.
    await arrives(bob, {
      'type': 'comment_hide', 'post_id': 'p1', 'comment_id': 'c1', 'hidden': true
    });
    expect(current().comments.single.hidden, isTrue);

    // Alice is the sphere's admin: allowed too.
    await arrives(alice, {
      'type': 'comment_pin', 'post_id': 'p1', 'comment_id': 'c1', 'pinned': true
    });
    expect(current().comments.single.pinned, isTrue);
  });

  test('a comment is deleted by its author or a moderator, not by a bystander',
      () async {
    await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
    await arrives(carol, commentFrom(carol, 'c1'));
    await arrives(carol, commentFrom(carol, 'c2'));

    final someone = key(ed.generateKey());
    await arrives(someone, {'type': 'comment_delete', 'post_id': 'p1', 'comment_id': 'c1'});
    expect(current().comments.length, 2);

    await arrives(carol, {'type': 'comment_delete', 'post_id': 'p1', 'comment_id': 'c1'});
    expect(current().comments.map((c) => c.id), ['c2']);

    await arrives(bob, {'type': 'comment_delete', 'post_id': 'p1', 'comment_id': 'c2'});
    expect(current().comments, isEmpty);
  });

  test('a closed post refuses new comments except from its author', () async {
    await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
    // Only the author may close it.
    await arrives(carol, {'type': 'post_settings', 'post_id': 'p1', 'comments_off': true});
    expect(current().commentsOff, isFalse);
    await arrives(bob, {'type': 'post_settings', 'post_id': 'p1', 'comments_off': true});
    expect(current().commentsOff, isTrue);

    await arrives(carol, commentFrom(carol, 'late'));
    expect(current().comments, isEmpty, reason: 'comments are off');
    await arrives(bob, commentFrom(bob, 'own'));
    expect(current().comments.map((c) => c.id), ['own']);
  });

  test('a reaction on a comment toggles, one per person, from the known set only',
      () async {
    await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
    await arrives(carol, commentFrom(carol, 'c1'));

    await arrives(bob, {'type': 'comment_react', 'post_id': 'p1', 'comment_id': 'c1', 'emoji': '👍'});
    expect(current().comments.single.hasReactionFrom(bob, '👍'), isTrue);

    await arrives(bob, {'type': 'comment_react', 'post_id': 'p1', 'comment_id': 'c1', 'emoji': '❤️'});
    final rs = current().comments.single.reactions;
    expect(rs.length, 1, reason: 'a second kind replaces the first');
    expect(rs.single.emoji, '❤️');

    await arrives(bob, {'type': 'comment_react', 'post_id': 'p1', 'comment_id': 'c1', 'emoji': '❤️'});
    expect(current().comments.single.reactions, isEmpty, reason: 'same kind again toggles off');

    await arrives(bob, {'type': 'comment_react', 'post_id': 'p1', 'comment_id': 'c1', 'emoji': '🍕'});
    expect(current().comments.single.reactions, isEmpty, reason: 'not a reaction kind');
  });

  test('malformed comment operations are dropped, never thrown', () async {
    await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
    await arrives(carol, commentFrom(carol, 'c1'));
    final kinds = ['comment_edit', 'comment_delete', 'comment_hide', 'comment_pin',
        'comment_react', 'post_settings'];
    final hostile = <Map<String, dynamic>>[
      {},
      {'post_id': 1},
      {'post_id': 'p1'},
      {'post_id': 'p1', 'comment_id': null},
      {'post_id': 'p1', 'comment_id': 'c1'},
      {'post_id': 'p1', 'comment_id': 'c1', 'text': 7, 'emoji': 7, 'hidden': 'x'},
      {'post_id': 'p1', 'comment_id': 'missing', 'text': 'x', 'emoji': '👍'},
      {'post_id': 'nope', 'comment_id': 'c1', 'comments_off': 'maybe'},
      {'post_id': 'p1', 'comment_id': 'c1', 'edited_at': 'not a date', 'text': 'x'},
    ];
    // Signed by a stranger, so even a well-formed one changes nothing.
    final stranger = key(ed.generateKey());
    for (final kind in kinds) {
      for (final body in hostile) {
        await arrives(stranger, {'type': kind, ...body});
      }
    }
    final c = current().comments.single;
    expect(c.id, 'c1');
    expect(c.text, 'c c1');
    expect(c.hidden, isFalse);
    expect(c.pinned, isFalse);
    expect(c.reactions, isEmpty);
    expect(current().commentsOff, isFalse);
  });

  group('who is told', () {
    late List<InboundEvent> events;
    late StreamSubscription<InboundEvent> sub;

    setUp(() {
      events = [];
      sub = InboundEvents.stream
          .where((e) => e.kind != InboundKind.post)
          .listen(events.add);
    });

    tearDown(() => sub.cancel());

    test('a reaction on my post notifies me; on someone else\'s it does not',
        () async {
      await arrives(alice, {'type': 'post', 'post': post(alice).toJson()});
      await arrives(bob, {'type': 'reaction', 'post_id': 'p1', 'emoji': '❤️'});
      await Future<void>.delayed(Duration.zero);
      expect(events.where((e) => e.kind == InboundKind.reaction).length, 1);

      events.clear();
      await arrives(bob, {'type': 'post', 'post': post(bob).copyWith(id: 'p2').toJson()});
      await arrives(carol, {'type': 'reaction', 'post_id': 'p2', 'emoji': '❤️'});
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });

    test('following a post brings its comments; muting one silences them',
        () async {
      await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
      await arrives(carol, commentFrom(carol, 'c1'));
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty, reason: 'not my post, not in the conversation');

      await feed.setPostNotifications('p1', true);
      await arrives(carol, commentFrom(carol, 'c2'));
      await Future<void>.delayed(Duration.zero);
      expect(events.single.kind, InboundKind.comment);

      events.clear();
      await feed.setPostNotifications('p1', false);
      await arrives(carol, commentFrom(carol, 'c3'));
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });

    test('a reply to my comment says so', () async {
      await arrives(bob, {'type': 'post', 'post': post(bob).toJson()});
      await arrives(alice, commentFrom(alice, 'mine'));
      await arrives(carol, commentFrom(carol, 'answer', replyTo: 'mine'));
      await Future<void>.delayed(Duration.zero);
      expect(events.single.title, contains('replied to your comment'));
    });
  });
}
