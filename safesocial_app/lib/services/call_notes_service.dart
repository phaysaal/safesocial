import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_log_service.dart';
import 'secure_store.dart';

/// One note the engine made from our own words in a call.
class CallNote {
  final String id;
  final String kind;
  final String description;
  final String? owner;
  final String? deadline;
  final String status;
  final bool uncertain;

  /// Milliseconds into the call's notes, as the engine placed it.
  final int atMs;

  /// When it was said, as a clock time: what two phones' notes are merged by.
  final DateTime at;

  /// Who said it, for notes that came from the other side; null for ours.
  final String? speaker;

  const CallNote({
    required this.id,
    required this.kind,
    required this.description,
    required this.at,
    this.owner,
    this.deadline,
    this.status = 'ACTIVE',
    this.uncertain = true,
    this.atMs = 0,
    this.speaker,
  });

  CallNote copyWith({String? description, String? speaker}) => CallNote(
        id: id,
        kind: kind,
        description: description ?? this.description,
        at: at,
        owner: owner,
        deadline: deadline,
        status: status,
        uncertain: uncertain,
        atMs: atMs,
        speaker: speaker ?? this.speaker,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'description': description,
        if (owner != null) 'owner': owner,
        if (deadline != null) 'deadline': deadline,
        'status': status,
        'uncertain': uncertain,
        'at': atMs,
        'time': at.toUtc().toIso8601String(),
      };

  /// [since] places a platform note, which carries only its offset, on the
  /// clock; a stored or received note carries its time already.
  static CallNote? tryParse(Object? raw, {DateTime? since}) {
    if (raw is! Map) return null;
    final id = raw['id'], kind = raw['kind'], description = raw['description'];
    if (id is! String || kind is! String || description is! String) return null;
    if (description.trim().isEmpty) return null;
    final atMs = raw['at'] is num ? (raw['at'] as num).toInt() : 0;
    final time = raw['time'] is String ? DateTime.tryParse(raw['time'] as String) : null;
    final at = time ?? (since ?? DateTime.now()).add(Duration(milliseconds: atMs));
    return CallNote(
      id: id,
      kind: kind,
      description: description,
      at: at,
      owner: raw['owner'] is String ? raw['owner'] as String : null,
      deadline: raw['deadline'] is String ? raw['deadline'] as String : null,
      status: raw['status'] is String ? raw['status'] as String : 'ACTIVE',
      uncertain: raw['uncertain'] != false,
      atMs: atMs,
    );
  }

  /// A word for the kind, as a person reads it.
  String get kindLabel => switch (kind) {
        'FACT' => 'Fact',
        'PROPOSAL' => 'Proposal',
        'DECISION' => 'Decision',
        'ACTION' => 'Action',
        'QUESTION' => 'Question',
        'CORRECTION' => 'Correction',
        _ => kind,
      };
}

/// The notes of one call, kept with its log entry.
class CallNotesRecord {
  final String logId;
  final String peer;

  /// When the notes began and when the call ended.
  final DateTime startedAt;
  final DateTime at;
  final String markdown;
  final List<CallNote> notes;

  const CallNotesRecord({
    required this.logId,
    required this.peer,
    required this.startedAt,
    required this.at,
    required this.markdown,
    required this.notes,
  });

  CallNotesRecord withNotes(List<CallNote> notes) => CallNotesRecord(
      logId: logId, peer: peer, startedAt: startedAt, at: at, markdown: markdown, notes: notes);

  /// Whether another phone's notes, taken between [from] and [to], are of
  /// this call. Clocks differ a little, so two minutes of slack either side.
  bool overlaps(DateTime from, DateTime to) {
    const slack = Duration(minutes: 2);
    return !to.isBefore(startedAt.subtract(slack)) && !from.isAfter(at.add(slack));
  }

  Map<String, dynamic> toJson() => {
        'logId': logId,
        'peer': peer,
        'started': startedAt.toUtc().toIso8601String(),
        'at': at.toIso8601String(),
        'markdown': markdown,
        'notes': notes.map((n) => n.toJson()).toList(),
      };

  static CallNotesRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final logId = raw['logId'], peer = raw['peer'];
    if (logId is! String || peer is! String) return null;
    final notes = (raw['notes'] as List? ?? const [])
        .map(CallNote.tryParse)
        .whereType<CallNote>()
        .toList();
    final at = DateTime.tryParse(raw['at'] as String? ?? '') ?? DateTime(2026);
    return CallNotesRecord(
      logId: logId,
      peer: peer,
      startedAt: DateTime.tryParse(raw['started'] as String? ?? '') ?? at,
      at: at,
      markdown: raw['markdown'] is String ? raw['markdown'] as String : '',
      notes: notes,
    );
  }
}

/// What a `call_notes` chat message carries: the other side's notes, with
/// their times, so they can be laid beside ours.
class SharedCallNotes {
  final DateTime startedAt;
  final DateTime endedAt;
  final String markdown;
  final List<CallNote> notes;

  const SharedCallNotes({
    required this.startedAt,
    required this.endedAt,
    required this.markdown,
    required this.notes,
  });

  /// From a message's payload, or null when it is not one.
  static SharedCallNotes? tryParse(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final started = DateTime.tryParse(payload['started'] as String? ?? '');
    final ended = DateTime.tryParse(payload['ended'] as String? ?? '');
    if (started == null || ended == null) return null;
    final notes = (payload['notes'] as List? ?? const [])
        .map(CallNote.tryParse)
        .whereType<CallNote>()
        .toList();
    if (notes.isEmpty) return null;
    return SharedCallNotes(
      startedAt: started,
      endedAt: ended,
      markdown: payload['markdown'] is String ? payload['markdown'] as String : '',
      notes: notes,
    );
  }
}

/// Notes from our own side of a call, made on the phone by the AutoEar
/// engine behind the `spheres/notes` channel. Off by default. What is kept
/// is notes and the engine's summary, sealed with the call log; the
/// transcript is never stored and never crosses this channel in the other
/// direction. The engine's own authors put about one admitted note in seven
/// at odds with what was said, so every note is shown as engine-made and
/// uncertain, and can be edited or deleted.
class CallNotesService extends ChangeNotifier {
  static const channel = MethodChannel('spheres/notes');
  static const _enabledKey = 'call_notes_enabled';
  static const _storeKey = 'spheres_call_notes_v1';

  /// What a person should know before turning it on.
  static const disclaimer =
      'Only your own voice is heard, on this phone, by its own speech recognition; the other '
      'person is not recorded and nothing is sent anywhere. The notes are made by rules, not '
      'by an understanding of the call: about one in seven can be wrong, and most of what was '
      'said is missed. The words themselves are never kept, only the notes.';

  bool _enabled = false;
  String? _unavailable;
  String _pendingMarkdown = '';
  final List<CallNote> _pendingNotes = [];
  DateTime? _startedAt;
  DateTime? _firstStartedAt;

  /// Supplies "now"; tests set it.
  DateTime Function() clock = DateTime.now;

  /// A call just ended with notes: (log id, peer) to offer sending them to.
  (String, String)? _shareOffer;
  (String, String)? get shareOffer => _shareOffer;
  void clearShareOffer() {
    _shareOffer = null;
    notifyListeners();
  }
  bool _checked = false;
  bool _taking = false;
  int _count = 0;
  String? _lastError;
  final Map<String, CallNotesRecord> _records = {};

  bool get enabled => _enabled;

  /// Why notes cannot be taken on this phone, once asked; null when they can.
  String? get unavailable => _unavailable;
  bool get taking => _taking;

  /// Notes admitted so far in the call in progress.
  int get count => _count;
  String? get lastError => _lastError;

  CallNotesRecord? recordFor(String logId) => _records[logId];
  bool hasNotes(String logId) => (_records[logId]?.notes.isNotEmpty ?? false);

  bool _listening = false;
  void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'note') {
        _count++;
        notifyListeners();
      }
    });
  }

  Future<void> load() async {
    _listen();
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    final raw = await SecureStore.instance.getString(_storeKey);
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          final r = CallNotesRecord.tryParse(e);
          if (r != null) _records[r.logId] = r;
        }
      } catch (e) {
        DebugLogService().warn('CallNotes', 'Stored notes unreadable: ${e.runtimeType}');
      }
    }
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    (await SharedPreferences.getInstance()).setBool(_enabledKey, on);
    if (on) await checkAvailable();
    notifyListeners();
  }

  /// Ask the platform whether notes can be taken here. Where there is no
  /// platform code the answer is that there is none.
  Future<void> checkAvailable() async {
    try {
      _unavailable = await channel.invokeMethod<String>('available');
    } on MissingPluginException {
      _unavailable = 'Not available on this platform';
    } on PlatformException catch (e) {
      _unavailable = e.message ?? 'Not available';
    }
    _checked = true;
    notifyListeners();
  }

  /// Notes were turned on in a call, by us or by the other side.
  Future<void> start(String callId) async {
    if (_taking) return;
    if (!_checked) await checkAvailable();
    if (_unavailable != null) return;
    _count = 0;
    _lastError = null;
    try {
      await channel.invokeMethod<void>('start', {'callId': callId});
      _taking = true;
      _startedAt = clock();
      _firstStartedAt ??= _startedAt;
      DebugLogService().info('CallNotes', 'Taking notes');
    } on MissingPluginException {
      _unavailable = 'Not available on this platform';
    } on PlatformException catch (e) {
      _lastError = e.message ?? 'Could not start';
      DebugLogService().warn('CallNotes', 'Not started: $_lastError');
    }
    notifyListeners();
  }

  /// Notes were turned off, or the call ended. Whatever the engine holds is
  /// held here until [finish], so notes turned on, off and on again in one
  /// call end up together.
  Future<void> stop() async {
    if (!_taking) return;
    _taking = false;
    Map<Object?, Object?>? out;
    try {
      out = await channel.invokeMethod<Map<Object?, Object?>>('stop');
    } on MissingPluginException {
      out = null;
    } on PlatformException catch (e) {
      _lastError = e.message;
    }
    final since = _startedAt ?? clock();
    final notes = ((out?['notes'] as List?) ?? const [])
        .map((n) => CallNote.tryParse(n, since: since))
        .whereType<CallNote>()
        .toList();
    final seen = _pendingNotes.map((n) => n.id).toSet();
    _pendingNotes.addAll(notes.where((n) => seen.add(n.id)));
    final md = out?['markdown'];
    if (md is String && md.trim().isNotEmpty) {
      _pendingMarkdown = _pendingMarkdown.isEmpty ? md : '$_pendingMarkdown\n\n$md';
    }
    _count = 0;
    notifyListeners();
  }

  /// The call ended: what was gathered is kept under its log entry and
  /// offered for sending to the other side. A call with no notes keeps
  /// nothing and offers nothing.
  Future<void> finish({required String logId, required String peer}) async {
    if (_taking) await stop();
    if (_pendingNotes.isNotEmpty) {
      final notes = List.of(_pendingNotes)..sort((a, b) => a.at.compareTo(b.at));
      _records[logId] = CallNotesRecord(
        logId: logId,
        peer: peer,
        startedAt: _firstStartedAt ?? clock(),
        at: clock(),
        markdown: _pendingMarkdown,
        notes: notes,
      );
      await _persist();
      DebugLogService().info('CallNotes', '${_pendingNotes.length} note(s) kept');
      _shareOffer = (logId, peer);
    }
    _pendingNotes.clear();
    _pendingMarkdown = '';
    _firstStartedAt = null;
    _startedAt = null;
    notifyListeners();
  }

  /// The structured form of [shareText], for the other phone to lay beside
  /// its own notes by time.
  Map<String, dynamic>? sharePayload(String logId) {
    final r = _records[logId];
    if (r == null || r.notes.isEmpty) return null;
    return {
      'started': r.startedAt.toUtc().toIso8601String(),
      'ended': r.at.toUtc().toIso8601String(),
      'markdown': r.markdown,
      'notes': r.notes.map((n) => n.toJson()).toList(),
    };
  }

  /// Our record of the call another phone's notes belong to, if any.
  CallNotesRecord? recordOverlapping(String peer, DateTime from, DateTime to) {
    for (final r in _records.values) {
      if (r.peer == peer && r.overlaps(from, to)) return r;
    }
    return null;
  }

  /// Both sides' notes as one list in the order things were said. Theirs
  /// are labelled with [theirName]; ours carry no label. Pure.
  static List<CallNote> merge(List<CallNote> mine, List<CallNote> theirs, {required String theirName}) {
    final all = [
      ...mine.map((n) => n.copyWith(speaker: null)),
      ...theirs.map((n) => n.copyWith(speaker: theirName)),
    ]..sort((a, b) {
        final c = a.at.compareTo(b.at);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    return all;
  }

  /// The notes of a call as one chat message for the other side: the
  /// summary when the engine wrote one, else the notes as lines, and a word
  /// on where they came from.
  String? shareText(String logId) {
    final r = _records[logId];
    if (r == null || r.notes.isEmpty) return null;
    final body = r.markdown.trim().isNotEmpty
        ? r.markdown.trim()
        : r.notes.map((n) => '• ${n.kindLabel}: ${n.description}').join('\n');
    return 'My notes from our call, made on my phone from my own words by rules, not by '
        'understanding, so some may be wrong:\n\n$body';
  }

  /// The person's word over the engine's.
  Future<void> editNote(String logId, String noteId, String description) async {
    final r = _records[logId];
    if (r == null) return;
    final text = description.trim();
    if (text.isEmpty) return deleteNote(logId, noteId);
    _records[logId] = r.withNotes(
        [for (final n in r.notes) n.id == noteId ? n.copyWith(description: text) : n]);
    await _persist();
    notifyListeners();
  }

  Future<void> deleteNote(String logId, String noteId) async {
    final r = _records[logId];
    if (r == null) return;
    final left = r.notes.where((n) => n.id != noteId).toList();
    if (left.isEmpty) {
      _records.remove(logId);
    } else {
      _records[logId] = r.withNotes(left);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> deleteAll(String logId) async {
    if (_records.remove(logId) == null) return;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() => SecureStore.instance.setString(
      _storeKey, jsonEncode(_records.values.map((r) => r.toJson()).toList()));
}
