import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact.dart';

/// Manages the user's contact list — adding, removing, and blocking peers.
///
/// Currently persists to SharedPreferences. In production, the contact list
/// will be stored in an encrypted local database with DHT-based mutual
/// verification (both parties must add each other).
class ContactService extends ChangeNotifier {
  static const _contactsKey = 'safesocial_contacts';

  List<Contact> _contacts = [];

  /// The current list of contacts.
  List<Contact> get contacts => List.unmodifiable(_contacts);

  /// Load contacts from local storage.
  Future<void> loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final contactsJson = prefs.getString(_contactsKey);
    if (contactsJson != null) {
      try {
        final list = jsonDecode(contactsJson) as List<dynamic>;
        _contacts = list
            .map((e) => Contact.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('[ContactService] Failed to load contacts: $e');
        _contacts = [];
      }
    }
    notifyListeners();
  }

  /// Add a new contact by public key and display name.
  Future<void> addContact(String publicKey, String displayName) async {
    // Avoid duplicates.
    if (_contacts.any((c) => c.publicKey == publicKey)) return;

    final contact = Contact(
      publicKey: publicKey,
      displayName: displayName,
      addedAt: DateTime.now(),
    );

    _contacts.add(contact);
    await _persistContacts();
    notifyListeners();
  }

  /// Remove a contact by public key.
  Future<void> removeContact(String publicKey) async {
    _contacts.removeWhere((c) => c.publicKey == publicKey);
    await _persistContacts();
    notifyListeners();
  }

  /// Toggle the blocked state of a contact.
  Future<void> toggleBlock(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;

    _contacts[index] = _contacts[index].copyWith(
      blocked: !_contacts[index].blocked,
    );
    await _persistContacts();
    notifyListeners();
  }

  /// Toggle the muted state of a contact.
  Future<void> toggleMute(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;

    _contacts[index] = _contacts[index].copyWith(
      muted: !_contacts[index].muted,
    );
    await _persistContacts();
    notifyListeners();
  }

  /// Toggle follow/unfollow. Unfollowed contacts stay connected
  /// but their posts are hidden from the feed.
  Future<void> toggleFollow(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;

    _contacts[index] = _contacts[index].copyWith(
      following: !_contacts[index].following,
    );
    await _persistContacts();
    notifyListeners();
  }

  /// Toggle close friend status.
  Future<void> toggleCloseFriend(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;

    _contacts[index] = _contacts[index].copyWith(
      closeFriend: !_contacts[index].closeFriend,
    );
    await _persistContacts();
    notifyListeners();
  }

  /// Look up a contact by public key.
  Contact? getContact(String publicKey) {
    try {
      return _contacts.firstWhere((c) => c.publicKey == publicKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_contacts.map((c) => c.toJson()).toList());
    await prefs.setString(_contactsKey, json);
  }
}
