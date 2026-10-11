import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// One device that belongs to an identity.
///
/// An identity is one Ed25519 key, held by every device the person uses. Each
/// device has its own X25519 key for deriving pairwise secrets, so two devices
/// never share a ratchet — sharing one is what made running two at once
/// corrupt conversations. The identity key signs each device's certificate,
/// so a contact can check that a device key really belongs to the person it
/// claims to, and a relay cannot slip one in.
class DeviceCert {
  static const _domain = 'spheres-device-v1';

  /// Ed25519 identity key, hex.
  final String identityKey;

  /// Random id, hex. Stable for the life of the install.
  final String deviceId;

  /// This device's X25519 public key, hex. What sessions are derived from.
  final String exchangeKey;

  /// A label the owner gave it, for their own device list. Not signed, so a
  /// contact never sees it.
  final String? name;

  final int createdAtMs;

  /// Ed25519 signature by [identityKey] over the signed fields, hex.
  final String signature;

  const DeviceCert({
    required this.identityKey,
    required this.deviceId,
    required this.exchangeKey,
    required this.createdAtMs,
    required this.signature,
    this.name,
  });

  static Uint8List _signedBytes(
    String identityKey,
    String deviceId,
    String exchangeKey,
    int createdAtMs,
  ) =>
      Uint8List.fromList(utf8.encode(
          [_domain, identityKey, deviceId, exchangeKey, '$createdAtMs'].join('\n')));

  /// Issue a certificate for a device. Only the identity key can.
  static DeviceCert issue({
    required String identityKey,
    required String identitySecret,
    required String deviceId,
    required String exchangeKey,
    String? name,
    int? createdAtMs,
  }) {
    final at = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final sig = ed.sign(
      ed.PrivateKey(hex.decode(identitySecret)),
      _signedBytes(identityKey, deviceId, exchangeKey, at),
    );
    return DeviceCert(
      identityKey: identityKey,
      deviceId: deviceId,
      exchangeKey: exchangeKey,
      createdAtMs: at,
      signature: hex.encode(sig),
      name: name,
    );
  }

  /// Whether [identityKey] really signed this.
  bool verify() {
    try {
      final key = hex.decode(identityKey);
      final sig = hex.decode(signature);
      if (key.length != 32 || sig.length != 64) return false;
      return ed.verify(
        ed.PublicKey(Uint8List.fromList(key)),
        _signedBytes(identityKey, deviceId, exchangeKey, createdAtMs),
        Uint8List.fromList(sig),
      );
    } catch (_) {
      return false;
    }
  }

  DeviceCert withName(String? newName) => DeviceCert(
        identityKey: identityKey,
        deviceId: deviceId,
        exchangeKey: exchangeKey,
        createdAtMs: createdAtMs,
        signature: signature,
        name: newName,
      );

  Map<String, dynamic> toJson({bool includeName = true}) => {
        'id': deviceId,
        'xk': exchangeKey,
        'at': createdAtMs,
        'sig': signature,
        if (includeName && name != null) 'name': name,
      };

  /// Parse one certificate for [identityKey]. Returns null for anything
  /// malformed; verification is separate so a caller can say which failed.
  static DeviceCert? fromJson(String identityKey, Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final xk = json['xk'];
    final at = json['at'];
    final sig = json['sig'];
    if (id is! String || xk is! String || at is! int || sig is! String) {
      return null;
    }
    if (!RegExp(r'^[0-9a-f]{2,64}$').hasMatch(id)) return null;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(xk)) return null;
    final name = json['name'];
    return DeviceCert(
      identityKey: identityKey,
      deviceId: id,
      exchangeKey: xk,
      createdAtMs: at,
      signature: sig,
      name: name is String ? name : null,
    );
  }
}

/// The signed set of devices an identity currently uses.
///
/// Revocation is publishing a new list without the device, with a higher
/// version; receivers keep the highest version they have verified. Note what
/// this can and cannot do: a revoked device stops being sent to, but it still
/// holds the identity secret and could sign as the owner. If a device was
/// stolen rather than retired, the identity itself has to be replaced.
class DeviceList {
  static const _domain = 'spheres-devices-v1';

  final String identityKey;
  final List<DeviceCert> devices;

  /// Monotonic. Milliseconds since the epoch at signing time, in practice.
  final int version;
  final String signature;

  const DeviceList({
    required this.identityKey,
    required this.devices,
    required this.version,
    required this.signature,
  });

  static Uint8List _signedBytes(
    String identityKey,
    int version,
    List<DeviceCert> devices,
  ) {
    final entries = devices.map((d) => '${d.deviceId}:${d.exchangeKey}').toList()
      ..sort();
    return Uint8List.fromList(
        utf8.encode([_domain, identityKey, '$version', ...entries].join('\n')));
  }

  static DeviceList sign({
    required String identityKey,
    required String identitySecret,
    required List<DeviceCert> devices,
    int? version,
  }) {
    final v = version ?? DateTime.now().millisecondsSinceEpoch;
    final sig = ed.sign(
      ed.PrivateKey(hex.decode(identitySecret)),
      _signedBytes(identityKey, v, devices),
    );
    return DeviceList(
      identityKey: identityKey,
      devices: List.unmodifiable(devices),
      version: v,
      signature: hex.encode(sig),
    );
  }

  /// The list signature and every certificate in it verify, and no two
  /// devices share an id or key.
  bool verify() {
    try {
      final key = hex.decode(identityKey);
      final sig = hex.decode(signature);
      if (key.length != 32 || sig.length != 64) return false;
      final ok = ed.verify(
        ed.PublicKey(Uint8List.fromList(key)),
        _signedBytes(identityKey, version, devices),
        Uint8List.fromList(sig),
      );
      if (!ok) return false;
    } catch (_) {
      return false;
    }
    final ids = <String>{};
    final keys = <String>{};
    for (final d in devices) {
      if (d.identityKey != identityKey) return false;
      if (!d.verify()) return false;
      if (!ids.add(d.deviceId) || !keys.add(d.exchangeKey)) return false;
    }
    return true;
  }

  List<String> get exchangeKeys => devices.map((d) => d.exchangeKey).toList();

  bool hasExchangeKey(String key) => devices.any((d) => d.exchangeKey == key);

  DeviceCert? byId(String id) {
    for (final d in devices) {
      if (d.deviceId == id) return d;
    }
    return null;
  }

  /// Names are the owner's business and stay local.
  Map<String, dynamic> toJson({bool includeNames = false}) => {
        'identity': identityKey,
        'version': version,
        'devices': devices.map((d) => d.toJson(includeName: includeNames)).toList(),
        'sig': signature,
      };

  static DeviceList? fromJson(Object? json) {
    if (json is! Map) return null;
    final identity = json['identity'];
    final version = json['version'];
    final sig = json['sig'];
    final raw = json['devices'];
    if (identity is! String || version is! int || sig is! String || raw is! List) {
      return null;
    }
    final devices = <DeviceCert>[];
    for (final item in raw) {
      final cert = DeviceCert.fromJson(identity, item);
      if (cert == null) return null;
      devices.add(cert);
    }
    if (devices.length > 32) return null;
    return DeviceList(
      identityKey: identity,
      devices: List.unmodifiable(devices),
      version: version,
      signature: sig,
    );
  }
}
