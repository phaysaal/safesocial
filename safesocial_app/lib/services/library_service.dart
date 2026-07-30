import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'secure_store.dart';

/// Purely local organisation: saved posts, muted spheres, pinned chats.
///
/// None of this is shared. Saving a post tells nobody, unlike a like — and on
/// a network with no server there is nothing that could learn it anyway. It is
/// grouped in one service because it is all the same shape: small sets of ids
/// the user curates, which have to survive a restart.
class LibraryService extends ChangeNotifier {
  static const _savedKey = 'spheres_saved_v1';
  static const _mutedKey = 'spheres_muted_spheres_v1';
  static const _pinnedKey = 'spheres_pinned_chats_v1';

  /// Collection name -> post ids. The default collection is always present so
  /// saving never requires choosing one first.
  static const String defaultCollection = 'Saved';

  final Map<String, List<String>> _collections = {defaultCollection: []};
  final Set<String> _mutedSpheres = {};
  final List<String> _pinnedChats = [];

  List<String> get collectionNames => _collections.keys.toList();

  List<String> postsIn(String collection) =>
      List.unmodifiable(_collections[collection] ?? const []);

  /// Every saved post id, across collections.
  Set<String> get allSavedPostIds =>
      _collections.values.expand((ids) => ids).toSet();

  bool isSaved(String postId) => allSavedPostIds.contains(postId);

  bool isMuted(String sphereId) => _mutedSpheres.contains(sphereId);

  bool isPinned(String chatKey) => _pinnedChats.contains(chatKey);

  /// Pinned chats in the order the user arranged them.
  List<String> get pinnedChats => List.unmodifiable(_pinnedChats);

  // ── Saves ─────────────────────────────────────────────────────────────────

  Future<void> toggleSave(String postId, {String? collection}) async {
    final target = collection ?? defaultCollection;
    _collections.putIfAbsent(target, () => []);

    if (isSaved(postId)) {
      // Unsaving removes it everywhere, so the toggle is not confusing when a
      // post sits in more than one collection.
      for (final ids in _collections.values) {
        ids.remove(postId);
      }
    } else {
      _collections[target]!.add(postId);
    }

    await _persistSaved();
    notifyListeners();
  }

  Future<void> createCollection(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || _collections.containsKey(trimmed)) return;
    _collections[trimmed] = [];
    await _persistSaved();
    notifyListeners();
  }

  Future<void> deleteCollection(String name) async {
    // The default collection is where an unfiled save lands, so it must exist.
    if (name == defaultCollection) return;
    if (_collections.remove(name) == null) return;
    await _persistSaved();
    notifyListeners();
  }

  /// Drop saved ids whose posts no longer exist, so the list cannot fill with
  /// references to content that expired or was deleted.
  Future<void> pruneMissing(Set<String> existingPostIds) async {
    var changed = false;
    for (final ids in _collections.values) {
      final before = ids.length;
      ids.removeWhere((id) => !existingPostIds.contains(id));
      if (ids.length != before) changed = true;
    }
    if (changed) {
      await _persistSaved();
      notifyListeners();
    }
  }

  // ── Muting ────────────────────────────────────────────────────────────────

  /// Muting hides a sphere's notifications and drops it out of the feed. It
  /// does not leave, and tells nobody.
  Future<void> toggleMute(String sphereId) async {
    if (!_mutedSpheres.remove(sphereId)) _mutedSpheres.add(sphereId);
    await SecureStore.instance
        .setStringList(_mutedKey, _mutedSpheres.toList());
    notifyListeners();
  }

  // ── Pinning ───────────────────────────────────────────────────────────────

  Future<void> togglePin(String chatKey) async {
    if (!_pinnedChats.remove(chatKey)) _pinnedChats.insert(0, chatKey);
    await SecureStore.instance.setStringList(_pinnedKey, _pinnedChats);
    notifyListeners();
  }

  /// Order conversations with pinned ones first, preserving the user's pin
  /// order and leaving everything else as it was.
  List<String> sortChats(List<String> chatKeys) {
    final pinned = _pinnedChats.where(chatKeys.contains);
    final rest = chatKeys.where((k) => !_pinnedChats.contains(k));
    return [...pinned, ...rest];
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> load() async {
    final store = SecureStore.instance;

    final savedRaw = await store.getString(_savedKey);
    if (savedRaw != null) {
      try {
        final decoded = jsonDecode(savedRaw) as Map<String, dynamic>;
        _collections
          ..clear()
          ..addAll(decoded.map(
              (k, v) => MapEntry(k, (v as List<dynamic>).cast<String>())));
        _collections.putIfAbsent(defaultCollection, () => []);
      } catch (_) {
        // Keep the empty default rather than losing the ability to save.
      }
    }

    _mutedSpheres.addAll(await store.getStringList(_mutedKey) ?? const []);
    _pinnedChats.addAll(await store.getStringList(_pinnedKey) ?? const []);
    notifyListeners();
  }

  Future<void> _persistSaved() =>
      SecureStore.instance.setString(_savedKey, jsonEncode(_collections));
}
