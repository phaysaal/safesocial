/// The writing guide: help with a message that stays the writer's own.
///
/// The second principle of the plan's §12.6: the app carries words and never
/// supplies them. So this guide has no sentences to offer. It knows, for each
/// kind of occasion, the questions only the writer can answer, in the order a
/// real message goes; it can tell, once and gently, when a draft could be said
/// to anyone; and that is all. Pure, so the rule can be tested.
library;

/// What the message is for. Declared by the writer, never detected.
enum Occasion {
  birthday,
  newRole,
  degree,
  project,
  award,
  founded,
  anniversary,
  milestone,
  childMoment,
  thanks,
  sympathy,
  reconnect,
  general;

  String get label => switch (this) {
        Occasion.birthday => 'A birthday',
        Occasion.newRole => 'A new role',
        Occasion.degree => 'A degree or exam passed',
        Occasion.project => 'Something they shipped or finished',
        Occasion.award => 'An award or recognition',
        Occasion.founded => 'Something they started',
        Occasion.anniversary => 'An anniversary',
        Occasion.milestone => 'A personal milestone',
        Occasion.childMoment => "A child's moment",
        Occasion.thanks => 'Thanks',
        Occasion.sympathy => 'Hard news',
        Occasion.reconnect => 'Getting back in touch',
        Occasion.general => 'Just a message',
      };
}

/// One question in the guide: shown faintly, skippable, never in the draft.
class GuideQuestion {
  final String text;

  /// A word or two for the step, as a heading above the question.
  final String step;
  const GuideQuestion(this.step, this.text);
}

class WritingGuide {
  WritingGuide._();

  /// The questions for an occasion, in the order a message goes: how to
  /// begin, then what only this writer knows, then the wish or the close.
  static List<GuideQuestion> questionsFor(Occasion o, {required String name}) {
    const begin = GuideQuestion('Begin', 'How do you want to begin? Their name, a greeting, or straight in.');
    final wish = GuideQuestion('Wish', 'What do you wish for $name now?');
    const close = GuideQuestion('Close', 'How do you want to end: a promise, a plan, a word you both use?');
    return switch (o) {
      Occasion.birthday => [
          begin,
          GuideQuestion('Notice', 'What did $name do this year that you noticed?'),
          GuideQuestion('Remember', 'What do you remember about $name that nobody else would say?'),
          wish,
        ],
      Occasion.newRole => [
          begin,
          GuideQuestion('Saw', 'What did you see $name do that led here?'),
          GuideQuestion('Know', 'What do you know about $name that the new place will find out?'),
          wish,
        ],
      Occasion.degree => [
          begin,
          const GuideQuestion('Remember', 'What do you remember of the long stretch before this?'),
          GuideQuestion('Changed', 'What did it change in $name, from where you stood?'),
          wish,
        ],
      Occasion.project => [
          begin,
          const GuideQuestion('Part', 'Which part of it did you see up close?'),
          const GuideQuestion('Hard', 'What was hard about it that others will not know?'),
          close,
        ],
      Occasion.award => [
          begin,
          const GuideQuestion('Before', 'What were they doing before anyone noticed?'),
          const GuideQuestion('Deserved', 'What makes this deserved, in one thing you saw?'),
          wish,
        ],
      Occasion.founded => [
          begin,
          GuideQuestion('Believe', 'What do you believe about $name that makes this work?'),
          const GuideQuestion('Offer', 'Is there something you can do for the start of it?'),
          wish,
        ],
      Occasion.anniversary => [
          begin,
          const GuideQuestion('Then', 'What was it like at the start, as you remember it?'),
          const GuideQuestion('Now', 'What is different now, that you are glad of?'),
          wish,
        ],
      Occasion.milestone => [
          begin,
          GuideQuestion('Watched', 'What did you watch $name go through for this?'),
          const GuideQuestion('Means', 'What do you think it means to them?'),
          wish,
        ],
      Occasion.childMoment => [
          begin,
          const GuideQuestion('Them', 'Say something to the child, not about them. What did you see?'),
          const GuideQuestion('Small', 'One small thing you noticed that they might not think anyone did?'),
          wish,
        ],
      Occasion.thanks => [
          begin,
          GuideQuestion('What', 'What exactly did $name do?'),
          const GuideQuestion('Meant', 'What did it make possible, or easier, for you?'),
          close,
        ],
      Occasion.sympathy => [
          begin,
          const GuideQuestion('Them', 'Say what you know of the person, or the loss, in plain words.'),
          const GuideQuestion('Here', 'What can you actually do, this week?'),
          const GuideQuestion('Close', 'End simply. Nothing needs to be fixed.'),
        ],
      Occasion.reconnect => [
          begin,
          GuideQuestion('Why', 'What made you think of $name today?'),
          const GuideQuestion('Then', 'One thing you remember from when you were in touch.'),
          const GuideQuestion('Ask', 'Ask them something only they can answer.'),
        ],
      Occasion.general => [
          begin,
          GuideQuestion('Say', 'What do you want $name to know?'),
          close,
        ],
    };
  }

  /// Words that mark a memory or a particular: a draft with one of these, or
  /// the person's name, is theirs and not anyone's.
  static const particulars = [
    'remember', 'when ', 'that time', 'last year', 'this year', 'the day', 'you said',
    'you did', 'you were', 'we were', 'at the', 'in the', 'your ',
  ];

  /// One gentle line when the draft could be said to anyone, else null.
  /// Never a judgement of quality, never blocking: a short draft gets nothing,
  /// a draft with their name or a memory in it gets nothing.
  static String? notice(String draft, {required String name}) {
    final text = draft.trim();
    if (text.length < 40) return null;
    final lower = ' ${text.toLowerCase()} ';
    final first = name.trim().split(RegExp(r'\s+')).first.toLowerCase();
    // Their name as a word, so "Al" is not found inside "all".
    if (first.isNotEmpty && RegExp('\\b${RegExp.escape(first)}\\b').hasMatch(lower)) return null;
    if (particulars.any(lower.contains)) return null;
    return 'This could be said to anyone yet. A memory, or ${name.trim().isEmpty ? 'their name' : first[0].toUpperCase() + first.substring(1)}, would make it theirs.';
  }

  /// A draft may be sent when it has words in it. The guide has no other say.
  static bool canSend(String draft) => draft.trim().isNotEmpty;
}
