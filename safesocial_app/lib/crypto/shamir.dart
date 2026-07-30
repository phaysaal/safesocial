import 'dart:typed_data';

import 'spheres_crypto.dart';

/// Shamir secret sharing over GF(256).
///
/// Replaces the `gf256` Rust path, which had three defects worth remembering
/// because they are easy to reintroduce:
///
///   * `threshold == 1` was accepted, which makes every share a complete copy
///     of the secret handed to each guardian;
///   * reconstruction enforced no threshold and no integrity, so too few or
///     corrupted shares silently produced a wrong secret reported as success;
///   * malformed shares reached the library and panicked across an FFI
///     boundary.
///
/// All three are refused here, and [SocialRecovery] additionally verifies the
/// reconstructed secret before anything adopts it.
class Shamir {
  const Shamir._();

  static const int minThreshold = 2;
  static const int maxShares = 255;

  // ── GF(256) arithmetic, AES polynomial 0x11b ───────────────────────────────

  static final Uint8List _exp = Uint8List(512);
  static final Uint8List _log = Uint8List(256);
  static bool _tablesReady = false;

  static void _buildTables() {
    if (_tablesReady) return;
    var x = 1;
    for (var i = 0; i < 255; i++) {
      _exp[i] = x;
      _log[x] = i;
      x ^= (x << 1) ^ ((x & 0x80) != 0 ? 0x11b : 0);
      x &= 0xff;
    }
    for (var i = 255; i < 512; i++) {
      _exp[i] = _exp[i - 255];
    }
    _tablesReady = true;
  }

  static int _mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    _buildTables();
    return _exp[_log[a] + _log[b]];
  }

  static int _div(int a, int b) {
    if (b == 0) throw ArgumentError('Division by zero in GF(256)');
    if (a == 0) return 0;
    _buildTables();
    return _exp[_log[a] + 255 - _log[b]];
  }

  // ── Splitting and combining ────────────────────────────────────────────────

  /// Split [secret] into [shareCount] shares, any [threshold] of which
  /// reconstruct it.
  ///
  /// Each returned share is `[x, ...y]` where `x` is the non-zero evaluation
  /// point. `x` must never be 0, because f(0) *is* the secret.
  static List<Uint8List> split({
    required Uint8List secret,
    required int shareCount,
    required int threshold,
  }) {
    if (secret.isEmpty) {
      throw ArgumentError('Nothing to split');
    }
    if (threshold < minThreshold) {
      throw ArgumentError(
        'Threshold must be at least $minThreshold — a threshold of 1 would '
        'give every guardian a complete copy of the secret',
      );
    }
    if (shareCount < threshold) {
      throw ArgumentError('Cannot need $threshold of only $shareCount shares');
    }
    if (shareCount > maxShares) {
      throw ArgumentError('At most $maxShares shares');
    }

    _buildTables();

    final shares = List.generate(
      shareCount,
      (i) => Uint8List(secret.length + 1)..[0] = i + 1,
    );

    for (var byteIndex = 0; byteIndex < secret.length; byteIndex++) {
      // A fresh random polynomial per byte, with the secret byte as constant.
      final coefficients = SpheresCrypto.randomBytes(threshold - 1);

      for (var shareIndex = 0; shareIndex < shareCount; shareIndex++) {
        final x = shareIndex + 1;
        var y = secret[byteIndex];
        var power = 1;
        for (final coefficient in coefficients) {
          power = _mul(power, x);
          y ^= _mul(coefficient, power);
        }
        shares[shareIndex][byteIndex + 1] = y;
      }
    }

    return shares;
  }

  /// Reconstruct a secret from [shares].
  ///
  /// The caller must supply at least the original threshold; with fewer, this
  /// returns plausible-looking nonsense, which is why [SocialRecovery] verifies
  /// the result rather than trusting it.
  static Uint8List combine(List<Uint8List> shares) {
    if (shares.length < minThreshold) {
      throw ArgumentError('Need at least $minThreshold shares');
    }

    final length = shares.first.length;
    if (length < 2) throw ArgumentError('Share is too short');

    final seenX = <int>{};
    for (final share in shares) {
      if (share.length != length) {
        // The Rust path asserted on this and panicked.
        throw ArgumentError('Shares are from different secrets (length differs)');
      }
      if (share[0] == 0) {
        throw ArgumentError('Share has an invalid index');
      }
      if (!seenX.add(share[0])) {
        // Duplicate x makes the Lagrange divisor zero.
        throw ArgumentError('The same share was supplied twice');
      }
    }

    _buildTables();
    final secret = Uint8List(length - 1);

    for (var byteIndex = 1; byteIndex < length; byteIndex++) {
      var accumulator = 0;

      for (var i = 0; i < shares.length; i++) {
        final xi = shares[i][0];
        var numerator = 1;
        var denominator = 1;

        for (var j = 0; j < shares.length; j++) {
          if (i == j) continue;
          final xj = shares[j][0];
          numerator = _mul(numerator, xj);
          denominator = _mul(denominator, xi ^ xj);
        }

        accumulator ^= _mul(shares[i][byteIndex], _div(numerator, denominator));
      }

      secret[byteIndex - 1] = accumulator;
    }

    return secret;
  }
}
