import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

import '../app_info.dart';
import '../crypto/blob.dart';
import '../crypto/sealed_box.dart';
import '../models/abuse_report.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// Sends reports to the people who run Spheres: sealed on this phone to the
/// operator's key, which the relay publishes at `GET /`, and posted to
/// `/report`. The relay keeps a box it cannot open. Returns null on success,
/// or why not, in words; it never claims a report went when it did not.
class ReportService {
  ReportService._();

  /// Overridable for tests: the HTTP call to the relay.
  static Future<http.Response> Function(Future<http.Response> Function(String host))? transport;

  static Future<http.Response> _call(Future<http.Response> Function(String host) f) =>
      (transport ?? relayHttp)(f);

  static AbuseReport build({
    required ReportReason reason,
    required String note,
    required ReportSubject subject,
    String? subjectId,
    String? author,
    String? authorName,
    String? text,
    List<String> media = const [],
  }) =>
      AbuseReport(
        id: const Uuid().v4(),
        at: DateTime.now(),
        reason: reason,
        note: note,
        subject: subject,
        subjectId: subjectId,
        author: author,
        authorName: authorName,
        text: text,
        media: media,
        appVersion: AppInfo.version,
      );

  /// The operator's key, or null when this relay takes no reports.
  static Future<String?> operatorKey() async {
    final res = await _call((host) => http.get(Uri.parse('https://$host/')));
    if (res.statusCode != 200) return null;
    final key = (jsonDecode(res.body) as Map<String, dynamic>)['report'];
    return key is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(key) ? key : null;
  }

  static Future<String?> send(AbuseReport report) async {
    try {
      final key = await operatorKey();
      if (key == null) return 'This relay does not take reports yet';
      final box = await SealedBox.seal(peerExchangeKeyHex: key, plaintext: report.toBytes());
      final res = await _call((host) => http.post(
            Uri.parse('https://$host/report'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'box': box}),
          ));
      if (res.statusCode == 200) {
        DebugLogService().info('Report', 'Report sent to the operator');
        return null;
      }
      if (res.statusCode == 429) return 'Too many reports from this phone today';
      return 'The relay answered ${res.statusCode}';
    } catch (e) {
      return 'Could not reach the relay: ${e.runtimeType}';
    }
  }

  /// Up to three of [refs] as small JPEGs, base64: a local file downscaled,
  /// or a blob's inline thumbnail when that is all this phone holds.
  static Future<List<String>> mediaFor(List<String> refs) async {
    final out = <String>[];
    for (final ref in refs) {
      if (out.length >= AbuseReport.maxMedia) break;
      try {
        final pending = BlobRef.tryDecode(ref);
        if (pending != null) {
          final thumb = pending.thumbnail;
          if (thumb != null) out.add(thumb.split(',').last);
          continue;
        }
        if (ref.startsWith('data:')) {
          out.add(ref.split(',').last);
          continue;
        }
        final file = File(ref);
        if (!file.existsSync()) continue;
        final decoded = img.decodeImage(await file.readAsBytes());
        if (decoded == null) continue;
        final small = decoded.width > 768 ? img.copyResize(decoded, width: 768) : decoded;
        out.add(base64Encode(img.encodeJpg(small, quality: 70)));
      } catch (_) {
        // A picture that cannot be read is left out, not faked.
      }
    }
    return out;
  }
}
