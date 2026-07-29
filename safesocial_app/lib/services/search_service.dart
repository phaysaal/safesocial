import '../models/contact.dart';
import '../models/message.dart';
import '../models/post.dart';
import '../models/sphere.dart';

enum SearchResultKind { contact, sphere, post, message }

class SearchResult {
  final SearchResultKind kind;

  /// Primary line — a name, or the author of the matched content.
  final String title;

  /// The matching text, trimmed around the hit.
  final String snippet;

  /// Where tapping the result should go.
  final String route;

  final DateTime? timestamp;

  const SearchResult({
    required this.kind,
    required this.title,
    required this.snippet,
    required this.route,
    this.timestamp,
  });
}

/// Local search across everything the device holds.
///
/// Search previously covered contact display names only, so there was no way
/// to find a message or a post at all.
///
/// Deliberately synchronous and in-memory: it runs over data already decrypted
/// in this process. Nothing is sent anywhere — there is no server that could
/// answer a query without being told what you are looking for.
class SearchService {
  const SearchService._();

  /// How much context to show either side of a hit.
  static const int _snippetPadding = 32;

  static List<SearchResult> search({
    required String query,
    required List<Contact> contacts,
    required List<Sphere> spheres,
    required List<Post> posts,
    required Map<String, List<Message>> conversations,
    String? myIdentityKey,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final results = <SearchResult>[];

    String nameFor(String key) {
      if (key == myIdentityKey) return 'You';
      for (final contact in contacts) {
        if (contact.publicKey == key) return contact.displayName;
      }
      return key.length > 8 ? '${key.substring(0, 8)}…' : key;
    }

    for (final contact in contacts) {
      if (contact.displayName.toLowerCase().contains(q) ||
          (contact.nickname?.toLowerCase().contains(q) ?? false) ||
          contact.publicKey.toLowerCase().contains(q)) {
        results.add(SearchResult(
          kind: SearchResultKind.contact,
          title: contact.displayName,
          snippet: contact.blocked ? 'Blocked contact' : 'Contact',
          route: '/chat/${contact.publicKey}',
          timestamp: contact.addedAt,
        ));
      }
    }

    for (final sphere in spheres) {
      if (sphere.name.toLowerCase().contains(q)) {
        results.add(SearchResult(
          kind: SearchResultKind.sphere,
          title: sphere.name,
          snippet:
              '${sphere.members.length} member${sphere.members.length == 1 ? '' : 's'}',
          route: '/sphere/${sphere.id}',
          timestamp: sphere.createdAt,
        ));
      }
    }

    for (final post in posts) {
      if (post.content.toLowerCase().contains(q)) {
        results.add(SearchResult(
          kind: SearchResultKind.post,
          title: nameFor(post.authorId),
          snippet: _snippet(post.content, q),
          route: '/post/${post.id}',
          timestamp: post.createdAt,
        ));
        continue;
      }

      // A comment matching is still a reason to surface the post.
      for (final comment in post.comments) {
        if (comment.text.toLowerCase().contains(q)) {
          results.add(SearchResult(
            kind: SearchResultKind.post,
            title: '${nameFor(comment.authorId)} commented',
            snippet: _snippet(comment.text, q),
            route: '/post/${post.id}',
            timestamp: comment.createdAt,
          ));
          break;
        }
      }
    }

    conversations.forEach((peerKey, messages) {
      for (final message in messages) {
        if (message.content.toLowerCase().contains(q)) {
          results.add(SearchResult(
            kind: SearchResultKind.message,
            title: nameFor(message.senderId),
            snippet: _snippet(message.content, q),
            route: '/chat/$peerKey',
            timestamp: message.timestamp,
          ));
        }
      }
    });

    // Newest first, with undated results last rather than dropped.
    results.sort((a, b) {
      final at = a.timestamp;
      final bt = b.timestamp;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });

    return results;
  }

  /// A window of [text] around the first hit, so long messages show the match
  /// rather than their opening words.
  static String _snippet(String text, String lowercaseQuery) {
    final index = text.toLowerCase().indexOf(lowercaseQuery);
    if (index == -1) return text;

    final start = (index - _snippetPadding).clamp(0, text.length);
    final end =
        (index + lowercaseQuery.length + _snippetPadding).clamp(0, text.length);

    final buffer = StringBuffer();
    if (start > 0) buffer.write('…');
    buffer.write(text.substring(start, end).trim());
    if (end < text.length) buffer.write('…');
    return buffer.toString();
  }
}
