import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../crypto/safety_number.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';

/// Compare keys with a contact, out of band.
///
/// Shows the safety number for this pair and a QR code of it. The other person
/// sees the same number on their phone if, and only if, both of you hold each
/// other's real keys. Read it to each other, or scan each other's code, then
/// mark the contact verified. If their keys later change, the mark is cleared
/// and the chat says so.
class VerifyContactScreen extends StatefulWidget {
  final String contactKey;
  const VerifyContactScreen({super.key, required this.contactKey});

  @override
  State<VerifyContactScreen> createState() => _VerifyContactScreenState();
}

class _VerifyContactScreenState extends State<VerifyContactScreen> {
  bool _scanning = false;
  String? _scanResult;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identity = context.watch<IdentityService>();
    final contacts = context.watch<ContactService>();
    final contact = contacts.getContact(widget.contactKey);
    final me = identity.publicKey;

    if (contact == null || me == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Verify encryption')),
        body: const Center(child: Text('This contact is no longer here.')),
      );
    }
    if (contact.allDeviceKeys.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Verify encryption')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Their encryption key has not arrived yet, so there is nothing to '
            'compare. Ask them to open the app, then come back.',
          ),
        ),
      );
    }

    final number = SafetyNumber.compute(
      myIdentity: me,
      myDeviceKeys: identity.deviceExchangeKeys,
      peerIdentity: contact.publicKey,
      peerDeviceKeys: contact.allDeviceKeys,
    );
    final state = contacts.verificationOf(contact.publicKey, number);

    return Scaffold(
      appBar: AppBar(title: Text('Verify ${contact.displayName}')),
      body: _scanning ? _scanner(number) : _details(theme, cs, contacts, contact, number, state),
    );
  }

  Widget _details(
    ThemeData theme,
    ColorScheme cs,
    ContactService contacts,
    contact,
    String number,
    ContactVerification state,
  ) {
    final groups = number.split(' ');
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (state == ContactVerification.changed)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Their keys have changed since you verified them. That happens '
              'when they add a device or reinstall — and it is also what an '
              'attack would look like. Compare again before trusting it.',
              style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
            ),
          ),
        Text(
          'Both of you should see the same sixty digits. If you do, nobody — '
          'not the relay, not anyone on the network — has swapped a key between '
          'you. Read them to each other, or scan the other phone.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: SafetyNumber.qrPayload(number),
              size: 200,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: number));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Safety number copied')));
          },
          child: GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 2.4,
            children: groups
                .map((g) => Center(
                      child: Text(
                        g,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 18, letterSpacing: 1.5),
                      ),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 20),
        if (state == ContactVerification.verified)
          ListTile(
            leading: Icon(Icons.verified, color: cs.primary),
            title: const Text('Verified'),
            subtitle: const Text('You confirmed these keys with them.'),
            trailing: TextButton(
              onPressed: () => contacts.clearVerified(widget.contactKey),
              child: const Text('Clear'),
            ),
          )
        else ...[
          FilledButton.icon(
            onPressed: () => setState(() {
              _scanning = true;
              _scanResult = null;
            }),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan their code'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await contacts.markVerified(widget.contactKey, number);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Marked as verified')));
              }
            },
            icon: const Icon(Icons.check),
            label: const Text('The numbers match — mark verified'),
          ),
        ],
        if (_scanResult != null) ...[
          const SizedBox(height: 12),
          Text(_scanResult!, style: TextStyle(color: cs.error)),
        ],
      ],
    );
  }

  Widget _scanner(String expected) {
    return Stack(
      children: [
        MobileScanner(
          onDetect: (capture) async {
            for (final barcode in capture.barcodes) {
              final raw = barcode.rawValue;
              if (raw == null) continue;
              final scanned = SafetyNumber.fromQr(raw);
              if (scanned == null) continue;
              if (!mounted) return;
              if (scanned == expected) {
                await context.read<ContactService>().markVerified(widget.contactKey, expected);
                if (!mounted) return;
                setState(() {
                  _scanning = false;
                  _scanResult = null;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Keys match. Marked as verified.')));
              } else {
                setState(() {
                  _scanning = false;
                  _scanResult = 'The codes do not match. Do not trust this '
                      'conversation until you know why.';
                });
              }
              return;
            }
          },
        ),
        Positioned(
          top: 16,
          left: 16,
          child: FilledButton.tonal(
            onPressed: () => setState(() => _scanning = false),
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }
}
