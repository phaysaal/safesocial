import 'dart:convert';

/// Why someone is reporting to the people who run Spheres. The first is the
/// one Play's child safety policy asks every social app to take.
enum ReportReason {
  childSafety('A child is at risk, or child sexual abuse material'),
  violence('Threats or violence'),
  harassment('Harassment or bullying'),
  selfHarm('Someone may hurt themselves'),
  illegal('Something else illegal'),
  scam('A scam, spam or impersonation'),
  other('Something else');

  final String label;
  const ReportReason(this.label);

  static ReportReason? parse(Object? v) {
    for (final r in values) {
      if (r.name == v) return r;
    }
    return null;
  }
}

/// What is being reported. A concern with nothing attached is a [general].
enum ReportSubject { post, message, comment, person, general }

/// A report to the operator, written on the reporter's phone. Pure.
///
/// The relay cannot read anyone's content, so the only way a report can show
/// what was said is for the reporter's phone, which holds it decrypted, to
/// include it. That is the reporter's choice ([includeContent]); the whole
/// report is then sealed to the operator's key, so the relay stores a box it
/// cannot open. The reporter's own key is not in it.
class AbuseReport {
  static const version = 1;
  static const maxMedia = 3;
  static const maxNote = 1000;
  static const maxText = 4000;

  final String id;
  final DateTime at;
  final ReportReason reason;
  final String note;
  final ReportSubject subject;
  final String? subjectId;

  /// The reported person's identity key, and the name the reporter knows
  /// them by.
  final String? author;
  final String? authorName;

  /// Included only when the reporter chose to include the content.
  final String? text;

  /// Small JPEGs, base64, at most [maxMedia].
  final List<String> media;
  final String appVersion;

  const AbuseReport({
    required this.id,
    required this.at,
    required this.reason,
    required this.note,
    required this.subject,
    required this.appVersion,
    this.subjectId,
    this.author,
    this.authorName,
    this.text,
    this.media = const [],
  });

  Map<String, dynamic> toJson() => {
        'v': version,
        'id': id,
        'at': at.toUtc().toIso8601String(),
        'reason': reason.name,
        if (note.trim().isNotEmpty) 'note': _cut(note.trim(), maxNote),
        'subject': subject.name,
        if (subjectId != null) 'subjectId': subjectId,
        if (author != null) 'author': author,
        if (authorName != null) 'authorName': authorName,
        if (text != null && text!.trim().isNotEmpty) 'text': _cut(text!, maxText),
        if (media.isNotEmpty) 'media': media.take(maxMedia).toList(),
        'app': appVersion,
      };

  List<int> toBytes() => utf8.encode(jsonEncode(toJson()));

  static AbuseReport? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final reason = ReportReason.parse(raw['reason']);
    final subject = ReportSubject.values.where((s) => s.name == raw['subject']).firstOrNull;
    final at = DateTime.tryParse(raw['at'] as String? ?? '');
    if (raw['v'] != version || reason == null || subject == null || at == null || raw['id'] is! String) {
      return null;
    }
    return AbuseReport(
      id: raw['id'] as String,
      at: at,
      reason: reason,
      note: raw['note'] is String ? raw['note'] as String : '',
      subject: subject,
      subjectId: raw['subjectId'] as String?,
      author: raw['author'] as String?,
      authorName: raw['authorName'] as String?,
      text: raw['text'] as String?,
      media: (raw['media'] as List? ?? const []).whereType<String>().take(maxMedia).toList(),
      appVersion: raw['app'] is String ? raw['app'] as String : '?',
    );
  }

  static String _cut(String s, int n) => s.length <= n ? s : s.substring(0, n);
}
