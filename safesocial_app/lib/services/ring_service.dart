import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/ring.dart';

/// Manages client-side audience rings.
class RingService extends ChangeNotifier {
  static const _prefsKey = 'spheres_rings';
  final List<Ring> _rings = [];

  List<Ring> get rings => List.unmodifiable(_rings);

  Future<void> loadRings() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefsKey);
    if (json != null) {
      final List<dynamic> list = jsonDecode(json);
      _rings.clear();
      _rings.addAll(list.map((e) => Ring.fromJson(e)));
    } else {
      // Default rings
      await _createDefaultRings();
    }
    notifyListeners();
  }

  Future<void> _createDefaultRings() async {
    _rings.addAll([
      const Ring(id: 'inner_circle', name: 'Inner Circle', color: Colors.green),
      const Ring(id: 'family', name: 'Family', color: Colors.blue),
    ]);
    await _persist();
  }

  Future<void> createRing(String name, Color color) async {
    final ring = Ring(id: const Uuid().v4(), name: name, color: color);
    _rings.add(ring);
    await _persist();
    notifyListeners();
  }

  Future<void> updateRing(Ring updated) async {
    final index = _rings.indexWhere((r) => r.id == updated.id);
    if (index != -1) {
      _rings[index] = updated;
      await _persist();
      notifyListeners();
    }
  }

  Future<void> deleteRing(String id) async {
    _rings.removeWhere((r) => r.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> addContactToRing(String ringId, String publicKey) async {
    final index = _rings.indexWhere((r) => r.id == ringId);
    if (index != -1) {
      final ring = _rings[index];
      if (!ring.memberPublicKeys.contains(publicKey)) {
        final newKeys = List<String>.from(ring.memberPublicKeys)..add(publicKey);
        _rings[index] = ring.copyWith(memberPublicKeys: newKeys);
        await _persist();
        notifyListeners();
      }
    }
  }

  Future<void> removeContactFromRing(String ringId, String publicKey) async {
    final index = _rings.indexWhere((r) => r.id == ringId);
    if (index != -1) {
      final ring = _rings[index];
      final newKeys = List<String>.from(ring.memberPublicKeys)..remove(publicKey);
      _rings[index] = ring.copyWith(memberPublicKeys: newKeys);
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_rings.map((e) => e.toJson()).toList()));
  }
}
