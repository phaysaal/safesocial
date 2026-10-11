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
  static const _archivedChatsKey = 'spheres_archived_chats_v1';
  static const _archivedSpheresKey = 'spheres_archived_spheres_v1';
  static const _mutedMembersKey = 'spheres_muted_members_v1';
  static const _starredKey = 'spheres_starred_v1';
  static const _lockedKey = 'spheres_locked_chats_v1';
  static const _appLockKey = 'spheres_app_lock';
  static const _hiddenWordsKey = 'spheres_hidden_words_v1';
  static const _memberNotesKey = 'spheres_member_notes_v1';
  static const _stickersKey = 'spheres_stickers_v1';
  static const _blurMediaKey = 'spheres_blur_media_v1';

  /// Collection name -> post ids. The default collection is always present so
  /// saving never requires choosing one first.
  static const String defaultCollection = 'Saved';

  final Map<String, List<String>> _collections = {defaultCollection: []};
  final Set<String> _mutedSpheres = {};
  final List<String> _pinnedChats = [];
  final Set<String> _archivedChats = {};
  final Set<String> _archivedSpheres = {};

  /// Sphere id -> members whose content is hidden there, without removing
  /// them. They are not told.
  final Map<String, Set<String>> _mutedMembers = {};

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

  // ── Blurred media ─────────────────────────────────────────────────────────

  /// Chats (by contact key) and spheres (by id) whose pictures and videos are
  /// shown blurred until tapped. Local only; nobody is told.
  final Set<String> _blurMedia = {};

  bool isMediaBlurred(String key) => _blurMedia.contains(key);

  /// Whether any of [keys] (a post can reach us through several spheres) asks
  /// for a blur.
  bool blursAnyOf(Iterable<String> keys) => keys.any(_blurMedia.contains);

  Future<void> toggleBlurMedia(String key) async {
    if (!_blurMedia.remove(key)) _blurMedia.add(key);
    await SecureStore.instance.setStringList(_blurMediaKey, _blurMedia.toList());
    notifyListeners();
  }

  // ── Starred messages, locked chats ────────────────────────────────────────

  /// Message ids the user starred, newest first, with the chat they live in.
  final List<MapEntry<String, String>> _starred = [];
  final Set<String> _lockedChats = {};
  bool _appLock = false;

  bool isStarred(String messageId) => _starred.any((e) => e.value == messageId);
  List<MapEntry<String, String>> get starred => List.unmodifiable(_starred);

  Future<void> toggleStar(String chatKey, String messageId) async {
    if (!_starred.any((e) => e.value == messageId)) {
      _starred.insert(0, MapEntry(chatKey, messageId));
    } else {
      _starred.removeWhere((e) => e.value == messageId);
    }
    await SecureStore.instance.setString(
        _starredKey, jsonEncode(_starred.map((e) => [e.key, e.value]).toList()));
    notifyListeners();
  }

  bool isChatLocked(String chatKey) => _lockedChats.contains(chatKey);
  bool get appLock => _appLock;

  Future<void> toggleChatLock(String chatKey) async {
    if (!_lockedChats.remove(chatKey)) _lockedChats.add(chatKey);
    await SecureStore.instance.setStringList(_lockedKey, _lockedChats.toList());
    notifyListeners();
  }

  Future<void> setAppLock(bool on) async {
    _appLock = on;
    await SecureStore.instance.setBool(_appLockKey, on);
    notifyListeners();
  }

  // ── Hidden words, member notes, stickers ──────────────────────────────────

  /// Words and phrases that hide a post or message on this device. Matching is
  /// case-insensitive and local; Meta runs the same feature on-device.
  final List<String> _hiddenWords = [];
  List<String> get hiddenWords => List.unmodifiable(_hiddenWords);

  bool hidesText(String text) {
    if (_hiddenWords.isEmpty || text.isEmpty) return false;
    final lower = text.toLowerCase();
    return _hiddenWords.any((w) => lower.contains(w));
  }

  Future<void> setHiddenWords(List<String> words) async {
    _hiddenWords
      ..clear()
      ..addAll(words.map((w) => w.trim().toLowerCase()).where((w) => w.isNotEmpty).toSet());
    await SecureStore.instance.setStringList(_hiddenWordsKey, _hiddenWords);
    notifyListeners();
  }

  /// Private notes about a member of a sphere, for admins' own memory. Never
  /// sent anywhere.
  final Map<String, Map<String, String>> _memberNotes = {};

  String? memberNote(String sphereId, String identityKey) => _memberNotes[sphereId]?[identityKey];

  Future<void> setMemberNote(String sphereId, String identityKey, String note) async {
    final notes = _memberNotes.putIfAbsent(sphereId, () => {});
    if (note.trim().isEmpty) {
      notes.remove(identityKey);
    } else {
      notes[identityKey] = note.trim();
    }
    if (notes.isEmpty) _memberNotes.remove(sphereId);
    await SecureStore.instance.setString(_memberNotesKey, jsonEncode(_memberNotes));
    notifyListeners();
  }

  /// Images saved as stickers, local paths. A sticker pack here is just the
  /// images one keeps; sharing one is sending it.
  final List<String> _stickers = [];
  List<String> get stickers => List.unmodifiable(_stickers);

  Future<void> addSticker(String path) async {
    if (_stickers.contains(path)) return;
    _stickers.insert(0, path);
    await SecureStore.instance.setStringList(_stickersKey, _stickers);
    notifyListeners();
  }

  Future<void> removeSticker(String path) async {
    _stickers.remove(path);
    await SecureStore.instance.setStringList(_stickersKey, _stickers);
    notifyListeners();
  }

  // ── Archiving ─────────────────────────────────────────────────────────────

  bool isChatArchived(String chatKey) => _archivedChats.contains(chatKey);
  bool isSphereArchived(String sphereId) => _archivedSpheres.contains(sphereId);
  int get archivedChatCount => _archivedChats.length;
  int get archivedSphereCount => _archivedSpheres.length;

  /// Archiving hides a chat from the main list without leaving it or deleting
  /// anything. New messages still arrive; the chat just stays out of the way.
  Future<void> toggleArchiveChat(String chatKey) async {
    if (!_archivedChats.remove(chatKey)) _archivedChats.add(chatKey);
    await SecureStore.instance.setStringList(_archivedChatsKey, _archivedChats.toList());
    notifyListeners();
  }

  Future<void> toggleArchiveSphere(String sphereId) async {
    if (!_archivedSpheres.remove(sphereId)) _archivedSpheres.add(sphereId);
    await SecureStore.instance
        .setStringList(_archivedSpheresKey, _archivedSpheres.toList());
    notifyListeners();
  }

  // ── Muting one member in one sphere ───────────────────────────────────────

  Set<String> mutedMembersIn(String sphereId) =>
      _mutedMembers[sphereId] ?? const <String>{};

  bool isMemberMuted(String sphereId, String identityKey) =>
      mutedMembersIn(sphereId).contains(identityKey);

  Future<void> toggleMuteMember(String sphereId, String identityKey) async {
    final set = _mutedMembers.putIfAbsent(sphereId, () => {});
    if (!set.remove(identityKey)) set.add(identityKey);
    if (set.isEmpty) _mutedMembers.remove(sphereId);
    await SecureStore.instance.setString(
      _mutedMembersKey,
      jsonEncode(_mutedMembers.map((k, v) => MapEntry(k, v.toList()))),
    );
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

  // ── Data saver, favourites feed, sphere snooze ────────────────────────

  static const _dataSaverKey = 'spheres_data_saver_v1';
  static const _favouritesFeedKey = 'spheres_feed_favourites_v1';
  static const _snoozedSpheresKey = 'spheres_snoozed_spheres_v1';
  bool _dataSaver = false;
  bool _favouritesFeed = false;
  final Map<String, DateTime> _snoozedSpheres = {};

  /// Pictures in arriving posts are not fetched until tapped.
  bool get dataSaver => _dataSaver;
  Future<void> setDataSaver(bool on) async {
    _dataSaver = on;
    await SecureStore.instance.setString(_dataSaverKey, on ? '1' : '0');
    notifyListeners();
  }

  /// The feed shows favourite contacts' posts only.
  bool get favouritesFeed => _favouritesFeed;
  Future<void> setFavouritesFeed(bool on) async {
    _favouritesFeed = on;
    await SecureStore.instance.setString(_favouritesFeedKey, on ? '1' : '0');
    notifyListeners();
  }

  DateTime? sphereSnoozedUntil(String sphereId) {
    final until = _snoozedSpheres[sphereId];
    return until != null && DateTime.now().isBefore(until) ? until : null;
  }

  bool isSphereSnoozed(String sphereId) => sphereSnoozedUntil(sphereId) != null;

  Future<void> snoozeSphere(String sphereId,
      {Duration duration = const Duration(days: 30)}) async {
    _snoozedSpheres[sphereId] = DateTime.now().add(duration);
    await _persistSnoozedSpheres();
    notifyListeners();
  }

  Future<void> unsnoozeSphere(String sphereId) async {
    _snoozedSpheres.remove(sphereId);
    await _persistSnoozedSpheres();
    notifyListeners();
  }

  /// Muted for good, or snoozed and not yet back: the spheres the feed skips.
  Set<String> get quietSpheres => {
        ..._mutedSpheres,
        for (final e in _snoozedSpheres.entries)
          if (DateTime.now().isBefore(e.value)) e.key,
      };

  Future<void> _persistSnoozedSpheres() => SecureStore.instance.setString(
      _snoozedSpheresKey,
      jsonEncode({for (final e in _snoozedSpheres.entries) e.key: e.value.toIso8601String()}));

  // ── Event reminders ───────────────────────────────────────────────────

  static const _eventRemindersKey = 'spheres_event_reminders_v1';
  final Map<String, List<int>> _eventReminders = {};

  /// Minutes before an event's start at which this device reminds us.
  List<int> eventReminders(String postId) =>
      List.unmodifiable(_eventReminders[postId] ?? const <int>[]);

  Map<String, List<int>> get allEventReminders => Map.unmodifiable(_eventReminders);

  Future<void> setEventReminders(String postId, List<int> minutesBefore) async {
    if (minutesBefore.isEmpty) {
      _eventReminders.remove(postId);
    } else {
      _eventReminders[postId] = (minutesBefore.toSet().toList()..sort());
    }
    await SecureStore.instance.setString(_eventRemindersKey, jsonEncode(_eventReminders));
    notifyListeners();
  }

  // ── Comment order ─────────────────────────────────────────────────────

  static const _commentOrderKey = 'spheres_comments_newest_v1';
  bool _commentsNewestFirst = false;

  /// Whether comment threads run newest-first. A reading preference, local.
  bool get commentsNewestFirst => _commentsNewestFirst;

  Future<void> setCommentsNewestFirst(bool newest) async {
    _commentsNewestFirst = newest;
    await SecureStore.instance.setString(_commentOrderKey, newest ? '1' : '0');
    notifyListeners();
  }

  Future<void> load() async {
    final store = SecureStore.instance;
    _commentsNewestFirst = (await store.getString(_commentOrderKey)) == '1';
    _dataSaver = (await store.getString(_dataSaverKey)) == '1';
    _favouritesFeed = (await store.getString(_favouritesFeedKey)) == '1';
    _eventReminders.clear();
    final remRaw = await store.getString(_eventRemindersKey);
    if (remRaw != null) {
      try {
        (jsonDecode(remRaw) as Map).forEach((k, v) {
          if (v is List) _eventReminders[k.toString()] = v.whereType<int>().toList();
        });
      } catch (_) {}
    }
    _snoozedSpheres.clear();
    final snoozedRaw = await store.getString(_snoozedSpheresKey);
    if (snoozedRaw != null) {
      try {
        (jsonDecode(snoozedRaw) as Map).forEach((k, v) {
          final until = v is String ? DateTime.tryParse(v) : null;
          if (until != null && DateTime.now().isBefore(until)) {
            _snoozedSpheres[k.toString()] = until;
          }
        });
      } catch (_) {}
    }

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
    _archivedChats.addAll(await store.getStringList(_archivedChatsKey) ?? const []);
    _archivedSpheres
        .addAll(await store.getStringList(_archivedSpheresKey) ?? const []);
    _hiddenWords.addAll(await store.getStringList(_hiddenWordsKey) ?? const []);
    _stickers.addAll(await store.getStringList(_stickersKey) ?? const []);
    final notesRaw = await store.getString(_memberNotesKey);
    if (notesRaw != null) {
      try {
        (jsonDecode(notesRaw) as Map<String, dynamic>).forEach((sphere, notes) {
          _memberNotes[sphere] = (notes as Map).cast<String, String>();
        });
      } catch (_) {}
    }
    _lockedChats.addAll(await store.getStringList(_lockedKey) ?? const []);
    _blurMedia.addAll(await store.getStringList(_blurMediaKey) ?? const []);
    _appLock = await store.getBool(_appLockKey) ?? false;
    final starredRaw = await store.getString(_starredKey);
    if (starredRaw != null) {
      try {
        for (final pair in jsonDecode(starredRaw) as List<dynamic>) {
          _starred.add(MapEntry(pair[0] as String, pair[1] as String));
        }
      } catch (_) {}
    }
    final mutedRaw = await store.getString(_mutedMembersKey);
    if (mutedRaw != null) {
      try {
        final decoded = jsonDecode(mutedRaw) as Map<String, dynamic>;
        decoded.forEach((sphere, keys) {
          _mutedMembers[sphere] = (keys as List<dynamic>).cast<String>().toSet();
        });
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _persistSaved() =>
      SecureStore.instance.setString(_savedKey, jsonEncode(_collections));
}
