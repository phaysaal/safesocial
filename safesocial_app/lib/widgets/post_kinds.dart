import 'package:flutter/material.dart';

import '../models/post.dart';
import '../services/feed_service.dart';
import 'avatar.dart';

/// The coloured backgrounds a short text post can sit on. Names travel in
/// `payload['bg']`; an unknown name renders as plain text, never as an error.
class PostBackgrounds {
  PostBackgrounds._();

  static const Map<String, List<Color>> all = {
    'sunset': [Color(0xFFFF6B6B), Color(0xFFFFA62B)],
    'ocean': [Color(0xFF2193B0), Color(0xFF6DD5ED)],
    'forest': [Color(0xFF134E5E), Color(0xFF71B280)],
    'berry': [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
    'dusk': [Color(0xFF2C3E50), Color(0xFF4CA1AF)],
    'rose': [Color(0xFFEE9CA7), Color(0xFFFFDDE1)],
    'ember': [Color(0xFF232526), Color(0xFF414345)],
    'mint': [Color(0xFF00B09B), Color(0xFF96C93D)],
  };

  static List<Color>? colorsFor(String? name) => name == null ? null : all[name];

  /// Backgrounds suit short text only; past this they are ignored.
  static const maxChars = 160;

  static Color textColorOn(String name) =>
      name == 'rose' ? const Color(0xFF3B1F24) : Colors.white;
}

/// A short post on a coloured background: big centred text.
class BackgroundTextCard extends StatelessWidget {
  final String text;
  final String background;

  const BackgroundTextCard({super.key, required this.text, required this.background});

  @override
  Widget build(BuildContext context) {
    final colors = PostBackgrounds.colorsFor(background) ?? PostBackgrounds.all['dusk']!;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 200),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: PostBackgrounds.textColorOn(background),
          fontSize: text.length > 80 ? 20 : 26,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }
}

/// The feelings a post can carry. Stored as `payload['feeling']`
/// `{emoji, label}`; an activity is `payload['activity']`, free text.
class Feelings {
  Feelings._();

  static const List<(String, String)> all = [
    ('😊', 'happy'),
    ('🥰', 'loved'),
    ('😎', 'cool'),
    ('🤩', 'excited'),
    ('😌', 'relaxed'),
    ('🙏', 'grateful'),
    ('😴', 'tired'),
    ('🤔', 'thoughtful'),
    ('😢', 'sad'),
    ('😤', 'annoyed'),
    ('🤒', 'sick'),
    ('🎉', 'festive'),
  ];

  /// "— feeling happy 😊" or "— watching the sea", or '' when neither.
  static String line(Map<String, dynamic>? payload) {
    if (payload == null) return '';
    final f = payload['feeling'];
    if (f is Map && f['label'] is String) {
      final emoji = f['emoji'] is String ? ' ${f['emoji']}' : '';
      return 'feeling ${f['label']}$emoji';
    }
    final a = payload['activity'];
    if (a is String && a.trim().isNotEmpty) return a.trim();
    return '';
  }
}

/// A life event: a flag, a title, a date.
class LifeEventCard extends StatelessWidget {
  final Post post;
  const LifeEventCard({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = post.payload ?? const {};
    final title = p['title'] is String ? p['title'] as String : post.content;
    final date = p['date'] is String ? p['date'] as String : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.flag, color: cs.onTertiaryContainer, size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Life event',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.onTertiaryContainer, letterSpacing: 1)),
                Text(title,
                    style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700, color: cs.onTertiaryContainer)),
                if (date.isNotEmpty)
                  Text(date,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onTertiaryContainer)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Any recommendations for…?": a question, and one suggestion per person.
class RecommendCard extends StatefulWidget {
  final Post post;
  final String? myKey;
  final String Function(String key) nameFor;
  final void Function(String text)? onSuggest;

  const RecommendCard({
    super.key,
    required this.post,
    required this.myKey,
    required this.nameFor,
    this.onSuggest,
  });

  @override
  State<RecommendCard> createState() => _RecommendCardState();
}

class _RecommendCardState extends State<RecommendCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = widget.post.payload ?? const {};
    final question = p['question'] is String ? p['question'] as String : widget.post.content;
    final suggestions =
        (p['suggestions'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final mine = suggestions[widget.myKey];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.lightbulb_outline, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Text('Asking for recommendations',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
          const SizedBox(height: 4),
          Text(question,
              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final e in suggestions.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UserAvatar(displayName: widget.nameFor(e.key), size: AvatarSize.small),
                  const SizedBox(width: 8),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: theme.textTheme.bodyMedium,
                        children: [
                          TextSpan(
                              text: '${widget.nameFor(e.key)} ',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          TextSpan(text: '${e.value}'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (suggestions.isEmpty)
            Text('No suggestions yet',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          if (widget.onSuggest != null)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: mine is String ? 'Change your suggestion' : 'Suggest something',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send_rounded), onPressed: _send),
                if (mine is String)
                  IconButton(
                    tooltip: 'Withdraw',
                    icon: const Icon(Icons.close),
                    onPressed: () => widget.onSuggest!(''),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSuggest!(text);
    _controller.clear();
  }
}

/// A post carried in from another sphere: who shared it, whose words they
/// are, and whether that is proven by the author's signature or only the
/// sharer's word.
class ReshareCard extends StatelessWidget {
  final Post post;
  final String Function(String key) nameFor;

  const ReshareCard({super.key, required this.post, required this.nameFor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final original = FeedService.originalOf(post);
    if (original == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text('A shared post that could not be read',
            style: theme.textTheme.bodySmall),
      );
    }
    final proven = FeedService.authorSignatureHolds(original);
    final authorName = original.authorName.isNotEmpty
        ? original.authorName
        : nameFor(original.authorId);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            UserAvatar(displayName: authorName, size: AvatarSize.small),
            const SizedBox(width: 8),
            Expanded(
              child: Text(authorName,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Tooltip(
              message: proven
                  ? 'The words carry the author\'s own signature'
                  : 'Attribution is the sharer\'s word; the original was not signed',
              child: Icon(
                proven ? Icons.verified : Icons.help_outline,
                size: 16,
                color: proven ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ]),
          if (original.content.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(original.content, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 4),
          Text(
            proven
                ? 'Signed by the author · pictures re-uploaded by the sharer'
                : 'As passed on by the sharer',
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
