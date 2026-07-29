import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/sphere.dart';
import 'debug_log_service.dart';
import 'sphere_service.dart';

/// One-time conversion of the old audience models into spheres.
///
/// Groups and rings both described "a named set of people", differently and
/// incompatibly, and neither affected who actually received anything. They
/// become spheres, which do.
///
/// The migration is deliberately conservative: it only creates spheres locally
/// and never broadcasts membership operations, because the old data was never
/// agreed with anyone else. The user has to invite people again, which is
/// honest — those groups only ever existed on their own device.
class SphereMigration {
  static const _doneKey = 'spheres_migrated_to_spheres_v1';

  static const _legacyGroupsKey = 'spheres_groups';
  static const _legacyRingsKey = 'spheres_rings';

  /// Run once per install. Returns the number of spheres created.
  static Future<int> run(SphereService sphereService) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return 0;
    if (!sphereService.isReady) return 0;

    var created = 0;
    created += await _migrateGroups(prefs, sphereService);
    created += await _migrateRings(prefs, sphereService);

    await prefs.setBool(_doneKey, true);
    if (created > 0) {
      DebugLogService()
          .success('Migration', 'Converted $created group(s)/ring(s) to spheres');
    }
    return created;
  }

  static Future<int> _migrateGroups(
    SharedPreferences prefs,
    SphereService sphereService,
  ) async {
    final raw = prefs.getString(_legacyGroupsKey);
    if (raw == null) return 0;

    var created = 0;
    try {
      for (final item in jsonDecode(raw) as List<dynamic>) {
        final group = item as Map<String, dynamic>;
        final name = group['name'] as String? ?? 'Group';
        final members = <String>[];

        for (final m in (group['members'] as List<dynamic>? ?? [])) {
          final key = (m as Map<String, dynamic>)['publicKey'];
          if (key is String && key.isNotEmpty) members.add(key);
        }

        await sphereService.create(
          name: name,
          kind: SphereKind.group,
          initialMembers: members,
        );
        created++;
      }
    } catch (e) {
      DebugLogService().error('Migration', 'Could not convert groups: $e');
    }
    return created;
  }

  static Future<int> _migrateRings(
    SharedPreferences prefs,
    SphereService sphereService,
  ) async {
    final raw = prefs.getString(_legacyRingsKey);
    if (raw == null) return 0;

    var created = 0;
    try {
      for (final item in jsonDecode(raw) as List<dynamic>) {
        final ring = item as Map<String, dynamic>;
        final members = <String>[];
        for (final key in (ring['memberPublicKeys'] as List<dynamic>? ?? [])) {
          if (key is String && key.isNotEmpty) members.add(key);
        }

        // Skip the two rings seeded on first run that were never populated —
        // migrating them would leave every user with empty "Inner Circle" and
        // "Family" spheres they never made.
        if (members.isEmpty) continue;

        await sphereService.create(
          name: ring['name'] as String? ?? 'Circle',
          kind: SphereKind.group,
          initialMembers: members,
        );
        created++;
      }
    } catch (e) {
      DebugLogService().error('Migration', 'Could not convert rings: $e');
    }
    return created;
  }
}
