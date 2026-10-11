import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// A number two people can compare out of band to confirm that the keys each
/// of them holds for the other are the real ones.
///
/// The relay publishes prekey bundles. They are signed by the identity key, so
/// a relay cannot swap a device key without that showing — but the identity
/// key itself arrived through a QR code or an invite link, and a link can be
/// tampered with before it is scanned. Comparing this number over a call or in
/// person closes that gap: it covers both identity keys and every device key
/// each side holds for the other, so a substituted key on either side changes
/// the digits for both people.
///
/// The same number is produced on both sides because the two blocks are
/// sorted by identity key before hashing.
class SafetyNumber {
  SafetyNumber._();

  static const _domain = 'spheres-safety-v1';

  /// Sixty digits in twelve groups of five, as a string with spaces.
  static String compute({
    required String myIdentity,
    required List<String> myDeviceKeys,
    required String peerIdentity,
    required List<String> peerDeviceKeys,
  }) {
    String block(String identity, List<String> keys) =>
        '$identity:${(List<String>.from(keys)..sort()).join(',')}';
    final blocks = [block(myIdentity, myDeviceKeys), block(peerIdentity, peerDeviceKeys)]
      ..sort();
    final input = utf8.encode('$_domain\n${blocks.join('\n')}');

    // Sixty digits need sixty bytes; two chained hashes give sixty-four.
    final first = sha256.convert(input).bytes;
    final second = sha256.convert([...input, ...first]).bytes;
    final bytes = [...first, ...second];

    final groups = <String>[];
    for (var i = 0; i < 12; i++) {
      var value = 0;
      for (var j = 0; j < 5; j++) {
        value = (value * 256 + bytes[i * 5 + j]) % 100000;
      }
      groups.add(value.toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  /// What goes in the QR code one side shows and the other scans.
  static String qrPayload(String number) =>
      'spheres-verify:${number.replaceAll(' ', '')}';

  /// The digits from a scanned QR payload, or null if it is not one of ours.
  static String? fromQr(String raw) {
    if (!raw.startsWith('spheres-verify:')) return null;
    final digits = raw.substring('spheres-verify:'.length);
    if (!RegExp(r'^\d{60}$').hasMatch(digits)) return null;
    return format(digits);
  }

  static String format(String digits) {
    final clean = digits.replaceAll(RegExp(r'\s'), '');
    final groups = <String>[];
    for (var i = 0; i + 5 <= clean.length; i += 5) {
      groups.add(clean.substring(i, i + 5));
    }
    return groups.join(' ');
  }
}
