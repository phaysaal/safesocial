import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/user_profile.dart';
import 'profile_sharing.dart';
import 'secure_store.dart';

/// Keeps every contact's copy of our profile current.
///
/// The profile used to go out only at the moment we edited it, and only to
/// contacts who already had a chat entry. So a contact added after the
/// picture was chosen saw an initial until our next edit, which could be
/// never. Now each contact is sent the profile when it differs from what
/// they were last sent: on every edit, when they are added, and at every
/// start. Our own other devices get the whole profile on the same terms, and
/// a device linked since the last send counts as a change. What they were sent is remembered as a digest of the cut built for
/// them with local refs, so a contact who starts sharing a sphere with us,
/// and may therefore see more, gets the wider cut on the next start.
///
/// Pure coordination: the profile, the peers, the blob upload and the sealed
/// send are all handed in, so the behaviour is testable without a relay.
class ProfileSync {
  ProfileSync({
    required this.profile,
    required this.peers,
    required this.sharedSpheres,
    required this.restricted,
    required this.upload,
    required this.send,
    required this.sendOwn,
    required this.everything,
    this.ownDevices,
  });

  static const _key = 'spheres_profile_sent_v1';

  final UserProfile? Function() profile;

  /// Every contact who should hold a copy: not blocked, able to be sealed to.
  final Iterable<String> Function() peers;
  final Set<String> Function(String peer) sharedSpheres;
  final bool Function(String peer) restricted;

  /// A local path to a relay reference, or null when it cannot be uploaded.
  final Future<String?> Function(String local) upload;

  /// Seals and sends one `profile` envelope; true only when the relay took it.
  final Future<bool> Function(String peer, Map<String, dynamic> payload) send;

  /// The whole profile, for our own other devices.
  final Future<void> Function(Map<String, dynamic> everything) sendOwn;

  /// Our device ids. Part of what "sent to our devices" means, so a device
  /// linked after the last send is owed the whole profile, picture included.
  final Iterable<String> Function()? ownDevices;
  final Map<String, dynamic> Function({
    String? avatarRef,
    String? coverRef,
    List<String> featuredRefs,
    Map<String, List<String>> highlightRefs,
  }) everything;

  final Map<String, String> _sent = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await SecureStore.instance.getString(_key);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        map.forEach((k, v) {
          if (k is String && v is String) _sent[k] = v;
        });
      }
    } catch (_) {}
  }

  Future<void> _save() => SecureStore.instance.setString(_key, jsonEncode(_sent));

  /// What [peer] was last sent, as a digest; null when never.
  String? lastSentTo(String peer) => _sent[peer];

  /// Forget a contact who is gone, so a re-add starts afresh.
  Future<void> forget(String peer) async {
    if (_sent.remove(peer) != null) await _save();
  }

  Map<String, dynamic> _cutFor(UserProfile p, String peer, {
    required String? avatar,
    required String? cover,
    required List<String> featured,
    required Map<String, List<String>> highlights,
  }) =>
      ProfileSharing.payloadFor(
        profile: p,
        peer: peer,
        sharedSpheres: sharedSpheres(peer),
        avatarRef: avatar,
        coverRef: cover,
        featuredRefs: featured,
        restricted: restricted(peer),
        highlightRefs: highlights,
      );

  /// The digest of the cut [peer] would get, computed over local refs so it
  /// is stable across uploads.
  String digestFor(UserProfile p, String peer) {
    final cut = _cutFor(p, peer,
        avatar: p.avatarRef,
        cover: p.coverRef,
        featured: p.featuredRefs,
        highlights: {for (final h in p.highlights) h.id: h.refs});
    return sha256.convert(utf8.encode(jsonEncode(cut))).toString();
  }

  /// Send the profile to [to] (every peer when null). With [onlyChanged],
  /// a peer whose last copy matches is skipped. Our own devices get the
  /// whole profile whenever it changed. Returns the peers it went to.
  Future<List<String>> sync({Iterable<String>? to, bool onlyChanged = true}) async {
    await load();
    final p = profile();
    if (p == null) return const [];
    final targets = (to ?? peers()).toSet();
    final digests = {for (final peer in targets) peer: digestFor(p, peer)};
    final due = [
      for (final peer in targets)
        if (!onlyChanged || _sent[peer] != digests[peer]) peer,
    ];
    const ownKey = '';
    final ownDigest = sha256.convert(utf8.encode(jsonEncode({
      'profile': everything(
        avatarRef: p.avatarRef,
        coverRef: p.coverRef,
        featuredRefs: p.featuredRefs,
        highlightRefs: {for (final h in p.highlights) h.id: h.refs},
      ),
      'devices': (ownDevices?.call() ?? const <String>[]).toList()..sort(),
    }))).toString();
    final ownDue = to == null && (!onlyChanged || _sent[ownKey] != ownDigest);
    if (due.isEmpty && !ownDue) return const [];

    Future<String?> up(String? local) async {
      if (local == null || local.isEmpty) return null;
      try {
        return await upload(local);
      } catch (_) {
        return null;
      }
    }

    final avatar = await up(p.avatarRef);
    final cover = await up(p.coverRef);
    final featured = <String>[];
    for (final ref in p.featuredRefs) {
      final u = await up(ref);
      if (u != null) featured.add(u);
    }
    final highlights = <String, List<String>>{};
    for (final h in p.highlights) {
      highlights[h.id] = [
        for (final ref in h.refs)
          if (await up(ref) case final u?) u,
      ];
    }

    final went = <String>[];
    for (final peer in due) {
      try {
        final ok = await send(
            peer,
            _cutFor(p, peer,
                avatar: avatar, cover: cover, featured: featured, highlights: highlights));
        if (ok) {
          _sent[peer] = digests[peer]!;
          went.add(peer);
        }
      } catch (_) {
        // Not recorded, so the next start tries again.
      }
    }
    if (ownDue) {
      try {
        await sendOwn(everything(
            avatarRef: avatar, coverRef: cover, featuredRefs: featured, highlightRefs: highlights));
        _sent[ownKey] = ownDigest;
      } catch (_) {}
    }
    if (went.isNotEmpty || ownDue) await _save();
    return went;
  }
}
