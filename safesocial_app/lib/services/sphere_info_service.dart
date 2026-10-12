import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/sphere_info.dart';
import 'debug_log_service.dart';
import 'inbound_events.dart';
import 'secure_store.dart';
import 'sphere_service.dart';

/// Rules, join questions, topics, welcome line, guides, badges, suspensions
/// and admin automation, per sphere.
///
/// An admin publishes the whole [SphereInfo] as a `sphere_info` item; every
/// member keeps the newest version from an admin as of the membership they
/// hold. What each device does with it (drop a suspended member's post, mute
/// after N reports, retire an old invite link) is decided locally from the
/// copy it holds, like every other rule in this app.
class SphereInfoService extends ChangeNotifier {
  static const _infoKey = 'spheres_sphere_info_v1';
  static const _rulesSeenKey = 'spheres_rules_seen_v1';

  final SphereService _spheres;
  SphereInfoService(this._spheres);

  final Map<String, SphereInfo> _infos = {};
  final Map<String, int> _rulesSeen = {};

  /// Sends one sealed item to every member of a sphere. Set by the app.
  Future<void> Function({required String sphereId, required String type, required String payloadJson})? publish;

  /// Local: the admin's own keyword list per sphere. Set by the app.
  List<String> Function(String sphereId)? keywordsFor;

  /// Local: mute a member on this device. Set by the app.
  Future<void> Function(String sphereId, String member)? muteLocally;
  bool Function(String sphereId, String member)? isMutedLocally;

  SphereInfo infoFor(String sphereId) => _infos[sphereId] ?? SphereInfo.empty(sphereId);

  List<String> rulesFor(String sphereId) => infoFor(sphereId).rules;
  List<String> questionsFor(String sphereId) => infoFor(sphereId).questions;
  List<String> topicsFor(String sphereId) => infoFor(sphereId).topics;
  List<String> badgesFor(String sphereId, String member) => infoFor(sphereId).badgesOf(member);
  bool isSuspended(String sphereId, String member, {DateTime? now}) =>
      infoFor(sphereId).isSuspended(member, now: now);
  DateTime? suspendedUntil(String sphereId, String member) {
    final until = infoFor(sphereId).suspended[member];
    return until != null && DateTime.now().isBefore(until) ? until : null;
  }

  /// Rules this member has not yet acknowledged, or empty.
  List<String> unseenRules(String sphereId) {
    final info = infoFor(sphereId);
    if (info.rules.isEmpty) return const [];
    return (_rulesSeen[sphereId] ?? -1) >= info.version ? const [] : info.rules;
  }

  Future<void> markRulesSeen(String sphereId) async {
    _rulesSeen[sphereId] = infoFor(sphereId).version;
    await SecureStore.instance.setString(_rulesSeenKey, jsonEncode(_rulesSeen));
    notifyListeners();
  }

  /// Change a sphere's info and tell every member. Admins only.
  Future<SphereInfo> update(String sphereId, SphereInfo Function(SphereInfo current) change) async {
    final sphere = _spheres.sphere(sphereId);
    final me = _spheres.myIdentityKey;
    if (sphere == null || me == null) throw StateError('Unknown sphere');
    if (!sphere.isAdmin(me)) throw StateError('Only an admin can change the rules of "${sphere.name}"');
    final current = infoFor(sphereId);
    final next = change(current).copyWith(version: current.version + 1, by: me, updatedAt: DateTime.now());
    _infos[sphereId] = next;
    await _persist();
    notifyListeners();
    final send = publish;
    if (send == null) throw StateError('Nothing can send sphere items yet');
    await send(sphereId: sphereId, type: 'sphere_info', payloadJson: jsonEncode({'type': 'sphere_info', 'info': next.toJson()}));
    return next;
  }

  /// A `sphere_info` item arrived. [authorId] is the verified signer.
  Future<void> handleIncoming(String authorId, String sphereId, Map<String, dynamic> json) async {
    final sphere = _spheres.sphere(sphereId);
    if (sphere == null) return;
    if (!sphere.isAdmin(authorId)) {
      DebugLogService().warn('SphereInfo', 'Rejecting sphere info: $authorId is not an admin');
      return;
    }
    final SphereInfo incoming;
    try {
      incoming = SphereInfo.fromJson((json['info'] as Map).cast<String, dynamic>());
    } catch (e) {
      DebugLogService().warn('SphereInfo', 'Malformed sphere info: $e');
      return;
    }
    if (incoming.sphereId != sphereId) return;
    final current = _infos[sphereId];
    if (current != null) {
      if (incoming.version < current.version) return;
      if (incoming.version == current.version && !incoming.updatedAt.isAfter(current.updatedAt)) return;
    }
    _infos[sphereId] = incoming.copyWith(by: authorId);
    await _persist();
    notifyListeners();
  }

  /// A post, comment or message from a suspended member is not shown; their
  /// own device refuses to send. Both from the same copy of the info.
  bool dropsContentFrom(String sphereId, String author) => isSuspended(sphereId, author);

  /// Keyword alerts for admins: local words, matched on content from others.
  /// Returns true when an alert was raised.
  bool keywordAlert(String sphereId, String authorId, String text, {required String route}) {
    final me = _spheres.myIdentityKey;
    final sphere = _spheres.sphere(sphereId);
    if (me == null || sphere == null || authorId == me || !sphere.isAdmin(me)) return false;
    final words = keywordsFor?.call(sphereId) ?? const [];
    final lower = text.toLowerCase();
    final hit = words.where((w) => w.trim().isNotEmpty && lower.contains(w.trim().toLowerCase())).toList();
    if (hit.isEmpty) return false;
    InboundEvents.emit(InboundEvent(
      kind: InboundKind.post,
      id: 'keyword:$sphereId:${text.hashCode}',
      title: 'Keyword in ${sphere.name}: ${hit.first}',
      body: text.length > 120 ? '${text.substring(0, 120)}…' : text,
      route: route,
      thread: 'keyword:$sphereId',
      from: authorId,
    ));
    return true;
  }

  /// Reports on one author's posts reached [count]; mute them here when the
  /// sphere's admins chose that. Returns true when a mute happened.
  Future<bool> reportsReached(String sphereId, String author, int count) async {
    final n = infoFor(sphereId).autoMuteReports;
    if (n == 0 || count < n) return false;
    if (isMutedLocally?.call(sphereId, author) ?? false) return false;
    await muteLocally?.call(sphereId, author);
    DebugLogService().info('SphereInfo', 'Muted a member here after $count report(s), as the sphere\'s rule says');
    return true;
  }

  Future<void> _persist() => SecureStore.instance
      .setString(_infoKey, jsonEncode(_infos.map((k, v) => MapEntry(k, v.toJson()))));

  Future<void> load() async {
    _infos.clear();
    final raw = await SecureStore.instance.getString(_infoKey);
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map).forEach((k, v) {
          if (v is Map) _infos['$k'] = SphereInfo.fromJson(v.cast<String, dynamic>());
        });
      } catch (e) {
        DebugLogService().error('SphereInfo', 'Could not read sphere info: $e');
      }
    }
    final seen = await SecureStore.instance.getString(_rulesSeenKey);
    if (seen != null) {
      try {
        (jsonDecode(seen) as Map).forEach((k, v) {
          if (v is int) _rulesSeen['$k'] = v;
        });
      } catch (_) {}
    }
  }
}
