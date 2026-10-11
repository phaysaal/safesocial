// Prints the device list a relay advertises for an identity. Debug aid.
import 'dart:convert';
import 'dart:io';
import 'package:spheres_app/crypto/mailbox.dart';

Future<void> main(List<String> args) async {
  final identity = args[0];
  final address = Mailbox.inboxIdFor(identity);
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse('https://relay.spheres.dev/prekey/$address'));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  stdout.writeln('status ${res.statusCode}');
  if (res.statusCode != 200) return;
  final env = jsonDecode(body) as Map<String, dynamic>;
  final bundle = env['bundle'] as Map<String, dynamic>;
  stdout.writeln('xk ${(bundle['keyExchangePublicKey'] as String?)?.substring(0, 12)}');
  stdout.writeln('relay ${bundle['relay']}');
  final devices = bundle['devices'];
  if (devices == null) {
    stdout.writeln('devices: none');
  } else {
    final d = devices as Map<String, dynamic>;
    stdout.writeln('devices version ${d['version']} count ${(d['devices'] as List).length}');
    for (final dev in d['devices'] as List) {
      final m = dev as Map<String, dynamic>;
      stdout.writeln('  ${m['name'] ?? m['n']} xk ${((m['exchangeKey'] ?? m['xk'] ?? m['x']) as String?)?.substring(0, 12)}');
    }
  }
  client.close();
}
