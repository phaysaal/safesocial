import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/contact.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/search_service.dart';

void main() {
  final alice = 'a' * 64;
  final bob = 'b' * 64;

  Contact contact(String key, String name, {bool blocked = false}) => Contact(
        publicKey: key,
        displayName: name,
        addedAt: DateTime(2026, 1, 1),
        blocked: blocked,
      );

  Post post(String id, String author, String content,
          {List<Comment> comments = const []}) =>
      Post(
        id: id,
        authorId: author,
        authorName: 'Author',
        content: content,
        createdAt: DateTime(2026, 2, 1),
        sphereId: 'sphere-1',
        comments: comments,
      );

  Message message(String content, {String? sender}) => Message(
        id: 'm-$content',
        senderId: sender ?? bob,
        recipientId: alice,
        content: content,
        timestamp: DateTime(2026, 3, 1),
      );

  Sphere sphere(String name) => Sphere(
        id: 'sphere-1',
        name: name,
        kind: SphereKind.group,
        createdBy: alice,
        createdAt: DateTime(2026, 1, 1),
        epoch: 1,
        members: [
          SphereMember(
            identityKey: alice,
            role: SphereRole.admin,
            joinedAt: DateTime(2026, 1, 1),
            invitedBy: alice,
          ),
        ],
      );

  List<SearchResult> run(
    String query, {
    List<Contact> contacts = const [],
    List<Sphere> spheres = const [],
    List<Post> posts = const [],
    Map<String, List<Message>> conversations = const {},
  }) =>
      SearchService.search(
        query: query,
        contacts: contacts,
        spheres: spheres,
        posts: posts,
        conversations: conversations,
        myIdentityKey: alice,
      );

  test('an empty query returns nothing', () {
    expect(run('', contacts: [contact(bob, 'Bob')]), isEmpty);
    expect(run('   ', contacts: [contact(bob, 'Bob')]), isEmpty);
  });

  test('finds contacts by name and by key', () {
    final contacts = [contact(bob, 'Barbara')];

    expect(run('barb', contacts: contacts).single.title, 'Barbara');
    expect(run(bob.substring(0, 10), contacts: contacts), hasLength(1));
  });

  test('finds spheres by name', () {
    final results = run('clim', spheres: [sphere('Climbing')]);

    expect(results.single.kind, SearchResultKind.sphere);
    expect(results.single.route, '/sphere/sphere-1');
  });

  test('finds posts by content — the old search could not', () {
    final results = run('harvest', posts: [post('p1', bob, 'the harvest is in')]);

    expect(results.single.kind, SearchResultKind.post);
    expect(results.single.route, '/post/p1');
  });

  test('finds messages, and routes to the conversation', () {
    final results = run('dentist', conversations: {
      bob: [message('remember the dentist')],
    });

    expect(results.single.kind, SearchResultKind.message);
    expect(results.single.route, '/chat/$bob');
  });

  test('a matching comment surfaces its post once', () {
    final results = run('agreed', posts: [
      post('p1', bob, 'unrelated body', comments: [
        Comment(
            id: 'c1',
            authorId: bob,
            authorName: 'Bob',
            text: 'agreed entirely',
            createdAt: DateTime(2026, 2, 2)),
        Comment(
            id: 'c2',
            authorId: bob,
            authorName: 'Bob',
            text: 'agreed again',
            createdAt: DateTime(2026, 2, 3)),
      ]),
    ]);

    expect(results, hasLength(1));
    expect(results.single.snippet, contains('agreed'));
  });

  test('search is case insensitive', () {
    expect(run('HARVEST', posts: [post('p1', bob, 'the harvest is in')]),
        hasLength(1));
  });

  test('own messages are attributed to You', () {
    final results = run('mine', conversations: {
      bob: [message('mine to send', sender: alice)],
    });

    expect(results.single.title, 'You');
  });

  test('results are newest first across kinds', () {
    final results = run('x', contacts: [
      contact(bob, 'x contact')
    ], posts: [
      post('p1', bob, 'x post')
    ], conversations: {
      bob: [message('x message')],
    });

    // Message (March) then post (February) then contact (January).
    expect(results.map((r) => r.kind).toList(), [
      SearchResultKind.message,
      SearchResultKind.post,
      SearchResultKind.contact,
    ]);
  });

  test('a long message is trimmed around the hit', () {
    final long = '${'padding ' * 40}needle${' padding' * 40}';
    final snippet = run('needle', conversations: {
      bob: [message(long)],
    }).single.snippet;

    expect(snippet, contains('needle'));
    expect(snippet.startsWith('…'), isTrue);
    expect(snippet.endsWith('…'), isTrue);
    expect(snippet.length, lessThan(120));
  });

  test('blocked contacts are still findable, and labelled', () {
    final results =
        run('barb', contacts: [contact(bob, 'Barbara', blocked: true)]);

    expect(results.single.snippet, 'Blocked contact');
  });
}
