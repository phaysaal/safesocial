import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// Manages the user's address book and contact handshakes.
class ContactService extends ChangeNotifier {
  static const _prefsContactsKey = 'spheres_contacts';

  final List<Contact> _contacts = [];
  final RelayService _handshakeRelay = RelayService();
  String? _myPublicKey;
  String? _myDisplayName;

  List<Contact> get contacts => List.unmodifiable(_contacts);

  void setMyInfo(String publicKey, String displayName) {
    _myPublicKey = publicKey;
    _myDisplayName = displayName;
    
    // Listen for incoming contact handshakes
    _handshakeRelay.onMessageReceived = (contactKey, data) {
      handleIncomingHandshake(contactKey, data);
    };
  }

  /// Add a contact and send a handshake request.
  Future<void> addContact(String publicKey, String displayName, {bool isPending = false}) async {
    if (_contacts.any((c) => c.publicKey == publicKey)) return;

    // Try to fetch their profile from Relay to get avatar/bio/latest name
    String finalName = displayName;
    try {
      final profileStr = await _handshakeRelay.pullState(publicKey, 'profile');
      if (profileStr != null) {
        final profile = jsonDecode(profileStr);
        if (profile['displayName'] != null) {
          finalName = profile['displayName'];
        }
      }
    } catch (_) {
      // Fallback to provided name
    }

    final contact = Contact(
      publicKey: publicKey,
      displayName: finalName,
      addedAt: DateTime.now(),
      isPending: isPending,
    );

    _contacts.add(contact);
    await _persistContacts();
    notifyListeners();

    // Send handshake via relay so they add us back
    if (_myPublicKey != null && !isPending) {
      _sendHandshake(publicKey, 'contact_request');
    }
  }

  /// Handle incoming handshake from another peer.
  void handleIncomingHandshake(String senderKey, String data) {
    try {
      final json = jsonDecode(data);
      final type = json['type'];
      final name = json['name'] ?? 'Unknown';
      final publicKey = json['publicKey'];

      if (type == 'contact_request') {
        DebugLogService().info('Contacts', 'Incoming contact request from $name');
        // Automatically add them as a pending contact
        addContact(publicKey, name, isPending: true);
        // Send back our info
        _sendHandshake(publicKey, 'contact_accept');
      } else if (type == 'contact_accept') {
        DebugLogService().success('Contacts', '$name accepted your request');
        _updateContactInfo(publicKey, name, isPending: false);
      }
    } catch (e) {
      DebugLogService().error('Contacts', 'Handshake error: $e');
    }
  }

  void _sendHandshake(String targetKey, String type) {
    final payload = jsonEncode({
      'type': type,
      'name': _myDisplayName ?? 'User',
      'publicKey': _myPublicKey,
    });
    
    _handshakeRelay.connect('handshake:$_myPublicKey', 'handshake:$targetKey').then((_) {
      _handshakeRelay.sendViaRelay('handshake:$targetKey', payload);
    });
  }

  Future<void> removeContact(String publicKey) async {
    _contacts.removeWhere((c) => c.publicKey == publicKey);
    await _persistContacts();
    notifyListeners();
  }

  Future<void> renameContact(String publicKey, String newName) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index != -1) {
      _contacts[index] = _contacts[index].copyWith(displayName: newName);
      await _persistContacts();
      notifyListeners();
    }
  }

  Future<void> toggleBlock(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index != -1) {
      _contacts[index] = _contacts[index].copyWith(blocked: !_contacts[index].blocked);
      await _persistContacts();
      notifyListeners();
    }
  }

  Future<void> toggleMute(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index != -1) {
      _contacts[index] = _contacts[index].copyWith(muted: !_contacts[index].muted);
      await _persistContacts();
      notifyListeners();
    }
  }

  Future<void> toggleFollow(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index != -1) {
      _contacts[index] = _contacts[index].copyWith(following: !_contacts[index].following);
      await _persistContacts();
      notifyListeners();
    }
  }

  Future<void> toggleCloseFriend(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index != -1) {
      _contacts[index] = _contacts[index].copyWith(closeFriend: !_contacts[index].closeFriend);
      await _persistContacts();
      notifyListeners();
    }
  }

  void _updateContactInfo(String publicKey, String name, {required bool isPending}) {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index != -1) {
      _contacts[index] = _contacts[index].copyWith(
        displayName: name,
        isPending: isPending,
      );
      _persistContacts();
      notifyListeners();
    }
  }

  Contact? getContact(String publicKey) {
    try {
      return _contacts.firstWhere((c) => c.publicKey == publicKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefsContactsKey);
    if (json != null) {
      final List<dynamic> list = jsonDecode(json);
      _contacts.clear();
      _contacts.addAll(list.map((e) => Contact.fromJson(e)));
    }
    notifyListeners();
  }

  Future<void> _persistContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsContactsKey, jsonEncode(_contacts.map((e) => e.toJson()).toList()));
  }
}
