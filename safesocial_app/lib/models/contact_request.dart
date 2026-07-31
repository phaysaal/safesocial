import 'package:equatable/equatable.dart';

/// Someone asking to be in touch, held until you decide.
///
/// Deliberately not a [Contact]. Until it is approved nothing is wired for
/// them — no chat, no feed, no call channel — and no reply is sent, so making
/// a request tells the sender nothing about whether the address exists or
/// whether anyone is there. Adding a contact used to be unilateral: anyone
/// holding your public key put themselves in your address book, which sat
/// oddly beside spheres, where joining has always needed an explicit yes.
class ContactRequest with EquatableMixin {
  /// Ed25519 identity key of whoever is asking, hex.
  final String publicKey;

  /// The name they gave. Not verified, and shown as their claim rather than
  /// as fact — anyone can call themselves anything.
  final String displayName;

  /// Their X25519 key, if the request carried one. Kept so approving does not
  /// need a round trip before anything can be encrypted.
  final String? keyExchangePublicKey;

  final DateTime receivedAt;

  const ContactRequest({
    required this.publicKey,
    required this.displayName,
    required this.keyExchangePublicKey,
    required this.receivedAt,
  });

  Map<String, dynamic> toJson() => {
        'publicKey': publicKey,
        'displayName': displayName,
        if (keyExchangePublicKey != null)
          'keyExchangePublicKey': keyExchangePublicKey,
        'receivedAt': receivedAt.toIso8601String(),
      };

  static ContactRequest fromJson(Map<String, dynamic> json) => ContactRequest(
        publicKey: json['publicKey'] as String,
        displayName: json['displayName'] as String? ?? 'Unknown',
        keyExchangePublicKey: json['keyExchangePublicKey'] as String?,
        receivedAt: DateTime.parse(json['receivedAt'] as String),
      );

  @override
  List<Object?> get props =>
      [publicKey, displayName, keyExchangePublicKey, receivedAt];
}
