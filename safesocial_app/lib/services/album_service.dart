import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/album.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// Manages collaborative shared photo albums.
class AlbumService extends ChangeNotifier {
  static const _albumsKey = 'spheres_albums';
  
  final List<Album> _albums = [];
  final RelayService _albumRelay = RelayService();
  String? _myPublicKey;
  String? _mySecretKey;

  List<Album> get albums => List.unmodifiable(_albums);

  void initSync(String myPublicKey, String mySecretKey) {
    _myPublicKey = myPublicKey;
    _mySecretKey = mySecretKey;
    _albumRelay.onMessageReceived = (albumKey, data) {
      _handleIncomingContribution(albumKey, data);
    };

    for (final album in _albums) {
      _albumRelay.connect('alb:${album.dhtKey}', 'alb:${album.dhtKey}', mySecretKey: _mySecretKey!, authPublicKey: myPublicKey);
    }
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

  Future<void> createAlbum(String name, String description) async {
    final album = Album(
      dhtKey: const Uuid().v4(),
      name: name,
      description: description,
      createdBy: _myPublicKey ?? 'self',
      createdAt: DateTime.now(),
      memberPublicKeys: [_myPublicKey ?? 'self'],
    );

    _albums.add(album);
    await _persist();
    notifyListeners();

    _albumRelay.connect('alb:${album.dhtKey}', 'alb:${album.dhtKey}', mySecretKey: _mySecretKey!, authPublicKey: _myPublicKey);
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

    _albums[index] = _albums[index].copyWith(
      items: [..._albums[index].items, item],
    );
    
    await _persist();
    notifyListeners();

    // Broadcast contribution to members
    final payload = jsonEncode({
      'type': 'album_add',
      'album_id': dhtKey,
      'item': item.toJson(),
    });
    _albumRelay.sendViaRelay('alb:$dhtKey', payload);
  }

  void _handleIncomingContribution(String albumKey, String data) {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'album_add') {
        final albumId = json['album_id'];
        final item = AlbumItem.fromJson(json['item']);
        
        final index = _albums.indexWhere((a) => a.dhtKey == albumId);
        if (index != -1) {
          if (!_albums[index].items.any((i) => i.id == item.id)) {
            _albums[index] = _albums[index].copyWith(
              items: [..._albums[index].items, item]..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
            );
            _persist();
            notifyListeners();
            DebugLogService().success('Media', 'New photo added to "${_albums[index].name}"');
          }
        }
      }
    } catch (e) {
      debugPrint('[AlbumService] Contribution error: $e');
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
