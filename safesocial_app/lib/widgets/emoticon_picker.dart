import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Custom emoticon definitions with #code# syntax.
class Emoticon {
  final String code;
  final String name;
  final String svgAsset;

  const Emoticon({
    required this.code,
    required this.name,
    required this.svgAsset,
  });
}

/// All available custom emoticons.
const emoticons = [
  Emoticon(code: 'carlita', name: 'Carlita', svgAsset: 'assets/emoticons/carlita.svg'),
  Emoticon(code: 'lemy', name: 'Lemy', svgAsset: 'assets/emoticons/lemy.svg'),
  Emoticon(code: 'love', name: 'Love', svgAsset: 'assets/emoticons/love.svg'),
  Emoticon(code: 'happy', name: 'Happy', svgAsset: 'assets/emoticons/happy.svg'),
  Emoticon(code: 'sad', name: 'Sad', svgAsset: 'assets/emoticons/sad.svg'),
  Emoticon(code: 'laugh', name: 'Laugh', svgAsset: 'assets/emoticons/laugh.svg'),
  Emoticon(code: 'star', name: 'Star', svgAsset: 'assets/emoticons/star.svg'),
  Emoticon(code: 'rainbow', name: 'Rainbow', svgAsset: 'assets/emoticons/rainbow.svg'),
  Emoticon(code: 'hug', name: 'Hug', svgAsset: 'assets/emoticons/hug.svg'),
  Emoticon(code: 'cool', name: 'Cool', svgAsset: 'assets/emoticons/cool.svg'),
  Emoticon(code: 'sparkle', name: 'Sparkle', svgAsset: 'assets/emoticons/sparkle.svg'),
  Emoticon(code: 'wink', name: 'Wink', svgAsset: 'assets/emoticons/wink.svg'),
  Emoticon(code: 'flower', name: 'Flower', svgAsset: 'assets/emoticons/flower.svg'),
];

/// Regex to match #code# patterns in text.
final _emoticonPattern = RegExp(r'#(\w+)#');

/// Find an emoticon by its code.
Emoticon? findEmoticon(String code) {
  try {
    return emoticons.firstWhere((e) => e.code == code);
  } catch (_) {
    return null;
  }
}

/// Check if a string contains only a single emoticon (for large display).
bool isSingleEmoticon(String text) {
  final trimmed = text.trim();
  final match = _emoticonPattern.firstMatch(trimmed);
  if (match == null) return false;
  return match.start == 0 && match.end == trimmed.length && findEmoticon(match.group(1)!) != null;
}

/// Render a message that may contain #code# emoticons.
/// Replaces #code# with inline SVG widgets.
Widget buildEmoticonText(String text, TextStyle? textStyle, {double emoticonSize = 48}) {
  final trimmed = text.trim();

  // Single emoticon — render large
  if (isSingleEmoticon(trimmed)) {
    final code = _emoticonPattern.firstMatch(trimmed)!.group(1)!;
    final emoticon = findEmoticon(code)!;
    return SvgPicture.asset(
      emoticon.svgAsset,
      width: emoticonSize * 2,
      height: emoticonSize * 2,
    );
  }

  // Mixed text + emoticons — render inline
  final parts = <InlineSpan>[];
  int lastEnd = 0;

  for (final match in _emoticonPattern.allMatches(text)) {
    // Text before the emoticon
    if (match.start > lastEnd) {
      parts.add(TextSpan(text: text.substring(lastEnd, match.start), style: textStyle));
    }

    // Emoticon
    final code = match.group(1)!;
    final emoticon = findEmoticon(code);
    if (emoticon != null) {
      parts.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: SvgPicture.asset(
            emoticon.svgAsset,
            width: emoticonSize,
            height: emoticonSize,
          ),
        ),
      ));
    } else {
      // Unknown code — keep as text
      parts.add(TextSpan(text: match.group(0), style: textStyle));
    }

    lastEnd = match.end;
  }

  // Remaining text after last emoticon
  if (lastEnd < text.length) {
    parts.add(TextSpan(text: text.substring(lastEnd), style: textStyle));
  }

  return RichText(text: TextSpan(children: parts));
}

/// Bottom sheet emoticon picker — tap to insert #code# into text field.
class EmoticonPicker extends StatelessWidget {
  final void Function(String code) onSelected;

  const EmoticonPicker({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Emoticons', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: emoticons.map((e) => GestureDetector(
              onTap: () => onSelected(e.code),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SvgPicture.asset(e.svgAsset),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    e.name,
                    style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            )).toList(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
