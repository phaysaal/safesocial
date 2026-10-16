import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/call_notes_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Notes from our side of a call: off by default, nothing asked of the
/// platform until turned on, honest where there is no platform, notes kept
/// sealed under the call's log entry and the person's edits kept over the
/// engine's words. The transcript never comes through the channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  Map<String, dynamic> note(String id, String kind, String text) => {
        'id': id, 'kind': kind, 'description': text, 'uncertain': true, 'status': 'ACTIVE', 'at': 1200,
      };

  void platform({String? unavailable, List<Map<String, dynamic>> notes = const [], String markdown = ''}) {
    messenger.setMockMethodCallHandler(CallNotesService.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'available':
          return unavailable;
        case 'start':
          if (unavailable != null) throw PlatformException(code: 'unavailable', message: unavailable);
          return null;
        case 'stop':
          return {'markdown': markdown, 'notes': notes};
      }
      return null;
    });
  }

  Future<void> fromPlatform(String method, Object? args) async {
    await messenger.handlePlatformMessage(
      CallNotesService.channel.name,
      CallNotesService.channel.codec.encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    calls = [];
  });

  tearDown(() => messenger.setMockMethodCallHandler(CallNotesService.channel, null));

  test('off by default: the setting that starts notes in every call is off', () async {
    platform();
    final s = CallNotesService();
    await s.load();
    expect(s.enabled, isFalse);
    expect(s.taking, isFalse);
    expect(calls, isEmpty, reason: 'nothing asked of the platform until a call turns notes on');
  });

  test('where there is no platform code, it says so and never claims to take notes', () async {
    final s = CallNotesService();
    await s.load();
    await s.setEnabled(true);
    expect(s.unavailable, 'Not available on this platform');
    await s.start('c1');
    expect(s.taking, isFalse);
  });

  test('the platform\'s reason not to is shown, and the switch stays honest', () async {
    platform(unavailable: 'Needs Android 13 or later');
    final s = CallNotesService();
    await s.load();
    await s.setEnabled(true);
    expect(s.unavailable, 'Needs Android 13 or later');
    await s.start('c1');
    expect(s.taking, isFalse);
    expect(calls.map((c) => c.method), isNot(contains('start')));
  });

  test('on: a call starts the engine, counts notes as they come, and keeps them at the end', () async {
    platform(
      notes: [note('n1', 'ACTION', 'Sarah will send the report by Friday'), note('n2', 'FACT', 'The deadline is Friday')],
      markdown: '## Deadline\n- The deadline is Friday',
    );
    final s = CallNotesService();
    await s.load();
    await s.setEnabled(true);
    await s.start('c1');
    expect(s.taking, isTrue);
    expect(calls.last.method, 'start');
    expect(calls.last.arguments, {'callId': 'c1'});

    await fromPlatform('note', note('n1', 'ACTION', 'Sarah will send the report by Friday'));
    expect(s.count, 1);

    await s.finish(logId: 'log-1', peer: 'bob');
    expect(s.taking, isFalse);
    expect(s.shareOffer, ('log-1', 'bob'));
    final r = s.recordFor('log-1')!;
    expect(r.notes.map((n) => n.id), ['n1', 'n2']);
    expect(r.notes.first.kindLabel, 'Action');
    expect(r.notes.first.uncertain, isTrue);
    expect(r.markdown, contains('Friday'));

    // Kept sealed, under the call's id, and only notes: no transcript field exists.
    final stored = await SecureStore.instance.getString('spheres_call_notes_v1');
    expect(stored, isNotNull);
    expect(stored, isNot(contains('transcript')));
    final again = CallNotesService();
    await again.load();
    expect(again.hasNotes('log-1'), isTrue);
    expect(jsonDecode(stored!), isA<List>());
  });

  test('a call with no notes keeps nothing', () async {
    platform();
    final s = CallNotesService();
    await s.load();
    await s.setEnabled(true);
    await s.start('c1');
    await s.finish(logId: 'log-2', peer: 'bob');
    expect(s.hasNotes('log-2'), isFalse);
    expect(s.shareOffer, isNull);
    expect(await SecureStore.instance.getString('spheres_call_notes_v1'), isNull);
  });

  test('the person\'s edit wins and a delete sticks; the last note gone drops the record', () async {
    platform(notes: [note('n1', 'FACT', 'The deadline is Friday'), note('n2', 'QUESTION', 'Is the venue booked')]);
    final s = CallNotesService();
    await s.load();
    await s.setEnabled(true);
    await s.start('c1');
    await s.finish(logId: 'log-3', peer: 'bob');

    await s.editNote('log-3', 'n1', 'The deadline is Thursday');
    expect(s.recordFor('log-3')!.notes.first.description, 'The deadline is Thursday');
    await s.deleteNote('log-3', 'n2');
    expect(s.recordFor('log-3')!.notes.length, 1);
    final again = CallNotesService();
    await again.load();
    expect(again.recordFor('log-3')!.notes.single.description, 'The deadline is Thursday');
    await again.deleteNote('log-3', 'n1');
    expect(again.hasNotes('log-3'), isFalse);
  });

  test('a malformed note from the platform is dropped, not shown half', () {
    expect(CallNote.tryParse({'id': 'x', 'kind': 'FACT'}), isNull);
    expect(CallNote.tryParse({'id': 'x', 'kind': 'FACT', 'description': '   '}), isNull);
    expect(CallNote.tryParse('nope'), isNull);
    expect(CallNote.tryParse(note('x', 'DECISION', 'We will go'))!.kindLabel, 'Decision');
  });

  test('notes turned on, off and on again in one call end up together, once each', () async {
    platform(notes: [note('n1', 'FACT', 'The deadline is Friday')], markdown: 'A');
    final s = CallNotesService();
    await s.load();
    await s.start('c1');
    await s.stop(); // the button, mid-call
    expect(s.hasNotes('log-4'), isFalse, reason: 'nothing is kept until the call ends');
    platform(notes: [note('n1', 'FACT', 'The deadline is Friday'), note('n2', 'ACTION', 'Sarah will send the report')], markdown: 'B');
    await s.start('c1');
    await s.finish(logId: 'log-4', peer: 'bob');
    final r = s.recordFor('log-4')!;
    expect(r.notes.map((n) => n.id), ['n1', 'n2']);
    expect(r.markdown, 'A\n\nB');
  });

  test('the text sent to the other side carries the summary and says what it is', () async {
    platform(notes: [note('n1', 'DECISION', 'We will meet on Tuesday')], markdown: '## Meeting\n- We will meet on Tuesday');
    final s = CallNotesService();
    await s.load();
    await s.start('c1');
    await s.finish(logId: 'log-5', peer: 'bob');
    final text = s.shareText('log-5')!;
    expect(text, contains('Tuesday'));
    expect(text, contains('made on my phone from my own words'));
    expect(text, contains('may be wrong'));
    expect(s.shareText('nope'), isNull);
    s.clearShareOffer();
    expect(s.shareOffer, isNull);
  });

  test('without a summary the notes themselves are the text', () async {
    platform(notes: [note('n1', 'ACTION', 'Sarah will send the report')]);
    final s = CallNotesService();
    await s.load();
    await s.start('c1');
    await s.finish(logId: 'log-6', peer: 'bob');
    expect(s.shareText('log-6'), contains('• Action: Sarah will send the report'));
  });

  group('time', () {
    test('a note carries the clock time it was said, not only its offset', () async {
      platform(notes: [note('n1', 'FACT', 'The deadline is Friday')]);
      final s = CallNotesService();
      var now = DateTime.utc(2026, 10, 16, 10, 0, 0);
      s.clock = () => now;
      await s.load();
      await s.start('c1');
      now = now.add(const Duration(minutes: 3));
      await s.finish(logId: 'log-7', peer: 'bob');
      final r = s.recordFor('log-7')!;
      expect(r.startedAt, DateTime.utc(2026, 10, 16, 10, 0, 0));
      expect(r.notes.single.at, DateTime.utc(2026, 10, 16, 10, 0, 1, 200), reason: '1200 ms in');
      expect(r.notes.single.toJson()['time'], '2026-10-16T10:00:01.200Z');
      // What travels to the other side carries the times and the span.
      final p = s.sharePayload('log-7')!;
      expect(p['started'], '2026-10-16T10:00:00.000Z');
      expect(p['ended'], '2026-10-16T10:03:00.000Z');
      expect((p['notes'] as List).single['time'], '2026-10-16T10:00:01.200Z');
      // And comes back out the same after a restart.
      final again = CallNotesService();
      await again.load();
      expect(again.recordFor('log-7')!.notes.single.at, DateTime.utc(2026, 10, 16, 10, 0, 1, 200));
    });

    test("both sides' notes merge in the order things were said, theirs labelled", () {
      CallNote at(String id, int s, {String? speaker}) => CallNote(
          id: id, kind: 'FACT', description: id, at: DateTime.utc(2026, 1, 1, 0, 0, s), speaker: speaker);
      final merged = CallNotesService.merge(
        [at('mine-2', 20), at('mine-1', 5)],
        [at('theirs-1', 10, speaker: 'stale label'), at('theirs-2', 20)],
        theirName: 'Bob',
      );
      expect(merged.map((n) => n.id), ['mine-1', 'theirs-1', 'mine-2', 'theirs-2']);
      expect(merged.map((n) => n.speaker), [null, 'Bob', null, 'Bob']);
    });

    test("the other side's notes are matched to our call by their span, with slack for clocks", () async {
      platform(notes: [note('n1', 'FACT', 'The deadline is Friday')]);
      final s = CallNotesService();
      var now = DateTime.utc(2026, 10, 16, 10);
      s.clock = () => now;
      await s.load();
      await s.start('c1');
      now = now.add(const Duration(minutes: 10));
      await s.finish(logId: 'log-8', peer: 'bob');

      final theirs = SharedCallNotes.tryParse({
        'started': '2026-10-16T10:01:00Z', 'ended': '2026-10-16T10:09:00Z',
        'notes': [note('t1', 'FACT', 'We agreed')..['time'] = '2026-10-16T10:02:00Z'],
      })!;
      expect(s.recordOverlapping('bob', theirs.startedAt, theirs.endedAt)?.logId, 'log-8');
      expect(s.recordOverlapping('carol', theirs.startedAt, theirs.endedAt), isNull);
      expect(s.recordOverlapping('bob', DateTime.utc(2026, 10, 16, 11), DateTime.utc(2026, 10, 16, 11, 5)), isNull,
          reason: 'an hour later is another call');
      expect(s.recordOverlapping('bob', DateTime.utc(2026, 10, 16, 10, 11), DateTime.utc(2026, 10, 16, 10, 15))?.logId, 'log-8',
          reason: 'a minute past our end is clock drift');
      expect(SharedCallNotes.tryParse({'started': 'x'}), isNull);
      expect(SharedCallNotes.tryParse({'started': '2026-10-16T10:01:00Z', 'ended': '2026-10-16T10:09:00Z', 'notes': []}), isNull);
    });
  });
}
