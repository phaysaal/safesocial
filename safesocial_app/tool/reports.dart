// The operator's side of "Report to Spheres". Runs on the operator's own
// computer; nothing here ships in the app.
//
//   dart run tool/reports.dart keygen          make the key pair and token (once)
//   dart run tool/reports.dart list            fetch, open and save every report
//   dart run tool/reports.dart delete <id>     remove a report from the relay
//   dart run tool/reports.dart ban <identity>  stop an identity being found or added
//   dart run tool/reports.dart unban <identity>
//
// The private key and the token live in ~/.config/spheres/operator.json
// (mode 600) and never in the repository. Opened reports are written to
// ~/.config/spheres/reports/<id>/.
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:http/http.dart' as http;
import 'package:spheres_app/crypto/mailbox.dart';
import 'package:spheres_app/crypto/sealed_box.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/models/abuse_report.dart';

final _home = Platform.environment['HOME'] ?? '.';
final _dir = Directory('$_home/.config/spheres');
final _config = File('${_dir.path}/operator.json');

Future<void> main(List<String> args) async {
  if (args.isEmpty) return _usage();
  switch (args.first) {
    case 'keygen':
      return _keygen();
    case 'list':
      return _list();
    case 'delete':
      if (args.length < 2) return _usage();
      return _delete(args[1]);
    case 'ban':
    case 'unban':
      if (args.length < 2) return _usage();
      return _ban(args[0], args[1]);
    default:
      return _usage();
  }
}

void _usage() {
  stderr.writeln('usage: dart run tool/reports.dart keygen | list | delete <id> | ban <identity> | unban <identity>');
  exitCode = 64;
}

Map<String, dynamic> _load() {
  if (!_config.existsSync()) {
    stderr.writeln('No ${_config.path}; run keygen first.');
    exit(1);
  }
  return jsonDecode(_config.readAsStringSync()) as Map<String, dynamic>;
}

Future<void> _keygen() async {
  if (_config.existsSync()) {
    stderr.writeln('${_config.path} exists; not overwriting. Delete it first to start over.');
    exit(1);
  }
  final pair = await SpheresCrypto.newKeyExchangeKeyPair();
  final private = await pair.extractPrivateKeyBytes();
  final public = (await pair.extractPublicKey()).bytes;
  final token = hex.encode(SpheresCrypto.randomBytes(32));
  _dir.createSync(recursive: true);
  _config.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'relay': 'https://relay.spheres.dev',
    'privateKey': hex.encode(private),
    'publicKey': hex.encode(public),
    'token': token,
  }));
  await Process.run('chmod', ['600', _config.path]);
  stdout.writeln('Wrote ${_config.path} (mode 600). Give the relay its half:');
  stdout.writeln('  echo ${hex.encode(public)} | npx wrangler secret put REPORT_PUBLIC_KEY');
  stdout.writeln('  echo <token from the file> | npx wrangler secret put REPORT_ADMIN_TOKEN');
}

Future<void> _list() async {
  final c = _load();
  final res = await http.get(Uri.parse('${c['relay']}/report'), headers: {'Authorization': 'Bearer ${c['token']}'});
  if (res.statusCode != 200) {
    stderr.writeln('Relay answered ${res.statusCode}');
    exit(1);
  }
  final pair = await SpheresCrypto.keyExchangeKeyPairFromPrivateBytes(hex.decode(c['privateKey'] as String));
  final items = jsonDecode(res.body) as List;
  if (items.isEmpty) stdout.writeln('No reports.');
  for (final item in items) {
    final id = item['id'] as String;
    final at = DateTime.fromMillisecondsSinceEpoch(item['at'] as int).toLocal();
    final opened = await SealedBox.open(myKeyPair: pair, box: item['box'] as String);
    final report = opened == null ? null : AbuseReport.tryParse(jsonDecode(utf8.decode(opened)));
    if (report == null) {
      stdout.writeln('$id  $at  (could not be opened with this key)');
      continue;
    }
    final out = Directory('${_dir.path}/reports/$id')..createSync(recursive: true);
    File('${out.path}/report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    for (var i = 0; i < report.media.length; i++) {
      File('${out.path}/picture_${i + 1}.jpg').writeAsBytesSync(base64Decode(report.media[i]));
    }
    final text = (report.text ?? report.note).replaceAll('\n', ' ');
    stdout.writeln('$id  $at  ${report.reason.name}  ${report.subject.name}'
        '${report.author == null ? '' : '  by ${report.authorName ?? '?'} (${report.author!.substring(0, 12)}…)'}'
        '  ${text.length > 60 ? '${text.substring(0, 60)}…' : text}'
        '${report.media.isEmpty ? '' : '  [${report.media.length} picture(s)]'}');
  }
  if (items.isNotEmpty) stdout.writeln('Saved under ${_dir.path}/reports/');
}

Future<void> _delete(String id) async {
  final c = _load();
  final res = await http.delete(Uri.parse('${c['relay']}/report/$id'), headers: {'Authorization': 'Bearer ${c['token']}'});
  stdout.writeln(res.statusCode == 200 ? 'Deleted $id from the relay.' : 'Relay answered ${res.statusCode}');
}

Future<void> _ban(String verb, String identity) async {
  final c = _load();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(identity)) {
    stderr.writeln('An identity is 64 hex characters (the "author" in a report).');
    exit(64);
  }
  final address = Mailbox.inboxIdFor(identity);
  final res = await http.post(Uri.parse('${c['relay']}/moderation/$verb/$address'),
      headers: {'Authorization': 'Bearer ${c['token']}'});
  stdout.writeln(res.statusCode == 200 ? '${verb == 'ban' ? 'Banned' : 'Unbanned'} $identity.' : 'Relay answered ${res.statusCode}');
}
