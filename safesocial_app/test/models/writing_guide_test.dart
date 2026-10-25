import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/models/writing_guide.dart';

/// The second principle: the app carries words and never supplies them. The
/// guide asks and notices; it has nothing to send.
void main() {
  test('every occasion has questions in the order a message goes, and none of them is a sentence to send', () {
    for (final o in Occasion.values) {
      final qs = WritingGuide.questionsFor(o, name: 'Al');
      expect(qs.length, greaterThanOrEqualTo(3), reason: o.name);
      expect(qs.first.step, 'Begin', reason: o.name);
      for (final q in qs) {
        expect(q.text, endsWith(RegExp(r'[?.]').firstMatch(q.text.substring(q.text.length - 1))?.group(0) ?? '?'),
            reason: 'a question or an instruction, not a line to paste');
        expect(q.text.toLowerCase(), isNot(contains('congratulations')));
        expect(q.text.toLowerCase(), isNot(contains('happy birthday')));
      }
    }
    expect(WritingGuide.questionsFor(Occasion.birthday, name: 'Al').map((q) => q.text).join(), contains('Al'));
  });

  test('a short draft gets no notice; so does one with their name or a memory in it', () {
    expect(WritingGuide.notice('Congrats!', name: 'Al Smith'), isNull);
    expect(WritingGuide.notice('Al, I remember the first week you started and how you got through it. Well done.', name: 'Al Smith'), isNull);
    expect(WritingGuide.notice('I was so glad when I heard, and I remember that time we talked about exactly this on the train.', name: 'Al Smith'), isNull);
    expect(WritingGuide.notice('You did the thing we talked about at the table and I am very happy for you tonight.', name: 'Al Smith'), isNull);
  });

  test('a draft that could be said to anyone gets one gentle line, naming them', () {
    final n = WritingGuide.notice(
        'Congratulations on this wonderful achievement, wishing you all the very best for the future ahead.',
        name: 'Al Smith');
    expect(n, 'This could be said to anyone yet. A memory, or Al, would make it theirs.');
    expect(WritingGuide.notice('Congratulations on this wonderful achievement, wishing you all the very best for the future.', name: ''),
        contains('their name'));
  });

  test('sending needs words and nothing else', () {
    expect(WritingGuide.canSend('   '), isFalse);
    expect(WritingGuide.canSend('ok'), isTrue);
    // The generic draft can still be sent: the guide notices, it does not block.
    expect(WritingGuide.canSend('Congratulations on this wonderful achievement, wishing you all the best.'), isTrue);
  });
}
