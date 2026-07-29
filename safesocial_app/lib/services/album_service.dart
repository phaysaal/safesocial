import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../crypto/mailbox.dart';
import '../models/album.dart';
import 'debug_log_service.dart';
import 'media_service.dart';
import 'relay_service.dart';
import 'sphere_service.dart';

/// Manages collaborative shared photo albums.
class AlbumService extends ChangeNotifier {
  static const _albumsKey = 'spheres_albums';
  
  final List<Album> _albums = [];
  final RelayService _albumRelay = RelayService();
  String? _myPublicKey;
  SphereService? _spheres;

  /// Supply the sphere context so album contents can be sealed.
  void attachSpheres(SphereService spheres) => _spheres = spheres;

  /// Handle a sealed album item delivered over the feed channels.
  Future<void> handleSealedItem(String sealed) async =>
      _handleIncomingContribution('feed', sealed);

  /// Albums whose sphere we are still a member of.
  List<Album> get visibleAlbums => _albums
      .where((a) => _spheres?.sphere(a.sphereId) != null)
      .toList(growable: false);

  List<Album> get albums => List.unmodifiable(_albums);

  /// Open an album channel. Same locality caveat as groups.
  Future<void> _connectAlbumMailbox(String dhtKey) async {
    final mailbox = await Mailbox.fromLocalSecret(
      secret: dhtKey,
      purpose: 'album',
    );
    await _albumRelay.connectMailbox('alb:$dhtKey', mailbox);
  }

  void initSync(String myPublicKey, String mySecretKey) {
    _myPublicKey = myPublicKey;
    _albumRelay.onMessageReceived = (channelKey, data) {
      _handleIncomingContribution(channelKey, data);
    };

    // Album traffic rides the same per-member channels the feed uses; there is
    // no separate album room any more.
  }

  Future<void> loadAlbums() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_albumsKey);
    if (json != null) {
      try {
        final List<dynamic> list = jsonDecode(json);
        _albums.clear();
        _albums.addAll(list.map((e) => Album.fromJson(e as Map<String, dynamic>)));
      } catch (e) {
        debugPrint('[AlbumService] Load failed: $e');
      }
    }
    notifyListeners();
  }

  Future<void> createAlbum(
      String name, String description, String sphereId) async {
    final album = Album(
      dhtKey: const Uuid().v4(),
      name: name,
      description: description,
      createdBy: _myPublicKey ?? 'self',
      createdAt: DateTime.now(),
      sphereId: sphereId,
    );

    _albums.add(album);
    await _persist();
    notifyListeners();

    _connectAlbumMailbox(album.dhtKey);
    DebugLogService().success('Media', 'Shared album "$name" created');
  }

  Future<void> addMediaToAlbum(String dhtKey, String mediaRef, String type) async {
    final index = _albums.indexWhere((a) => a.dhtKey == dhtKey);
    if (index == -1) return;

    final item = AlbumItem(
      id: const Uuid().v4(),
      authorId: _myPublicKey ?? 'self',
      mediaRef: mediaRef,
      type: type,
      addedAt: DateTime.now(),
    );

    final album = _albums[index].copyWith(
      items: [..._albums[index].items, item],
    );
    _albums[index] = album;

    await _persist();
    notifyListeners();

    final spheres = _spheres;
    final sphere = spheres?.sphere(album.sphereId);
    if (spheres == null || sphere == null) {
      DebugLogService()
          .warn('Media', 'Album "${album.name}" has no sphere; not shared');
      return;
    }

    // Send the image itself, not a path. Album items used to carry a local
    // filesystem path, which is a dead reference on anyone else's device — so
    // "shared" albums never actually shared anything.
    final encoded = await MediaService.encodeImageForRelay(mediaRef);
    final shared = encoded == null ? item : item.copyWith(mediaRef: encoded);

    final String sealed;
    try {
      sealed = await spheres.sealContent(
        sphereId: album.sphereId,
        type: 'album_add',
        plaintext: jsonEncode({
          'type': 'album_add',
          'album_id': dhtKey,
          'item': shared.toJson(),
        }),
      );
    } catch (e) {
      DebugLogService().error('Media', 'Could not seal album item: $e');
      return;
    }

    for (final member in sphere.members.map((m) => m.identityKey)) {
      if (member == _myPublicKey) continue;
      _albumRelay.sendViaRelay(member, sealed);
    }
  }

  Future<void> _handleIncomingContribution(String channelKey, String data) async {
    final spheres = _spheres;
    if (spheres == null) return;

    try {
      final opened = await spheres.openContent(data);
      final json = jsonDecode(opened.plaintext);
      if (json['type'] != 'album_add') return;

      final albumId = json['album_id'];
      var item = AlbumItem.fromJson(json['item']);

      final index = _albums.indexWhere((a) => a.dhtKey == albumId);
      if (index == -1) return;

      // The album must belong to the sphere the content was sealed to, or a
      // member of one sphere could inject items into an unrelated album.
      if (_albums[index].sphereId != opened.sphereId) {
        DebugLogService()
            .warn('Media', 'Album item sealed to the wrong sphere; dropped');
        return;
      }
      if (item.authorId != opened.from) {
        DebugLogService()
            .warn('Media', 'Album item author disagrees with signature');
        return;
      }
      if (_albums[index].items.any((i) => i.id == item.id)) return;

      final saved = await MediaService.decodeAndSaveImage(item.mediaRef);
      if (saved != null) item = item.copyWith(mediaRef: saved);
      // If the blob is not reachable yet the reference is kept, so the inline
      // thumbnail renders and the fetch can be retried later.

      _albums[index] = _albums[index].copyWith(
        items: [..._albums[index].items, item]
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
      );
      await _persist();
      notifyListeners();
      DebugLogService()
          .success('Media', 'New photo in "${_albums[index].name}"');
    } catch (e) {
      DebugLogService().warn('Media', 'Rejected album item: $e');
    }
  }

  Album? getAlbum(String dhtKey) {
    try {
      return _albums.firstWhere((a) => a.dhtKey == dhtKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_albumsKey, jsonEncode(_albums.map((e) => e.toJson()).toList()));
  }
}
