import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/contact.dart';
import '../models/friend_request.dart';

/// Manages contacts and friend request handshake.
///
/// When user A adds user B, a friend request is created.
/// B must also add A (or accept the request) for both to become
/// full friends. Until the handshake completes, the contact is
/// marked as pending.
class ContactService extends ChangeNotifier {
  static const _contactsKey = 'spheres_contacts';
  static const _requestsKey = 'spheres_friend_requests';

  List<Contact> _contacts = [];
  List<FriendRequest> _friendRequests = [];

  /// Confirmed contacts (both parties accepted).
  List<Contact> get contacts => List.unmodifiable(_contacts);

  /// All friend requests (incoming and outgoing).
  List<FriendRequest> get friendRequests => List.unmodifiable(_friendRequests);

  /// Pending incoming requests waiting for acceptance.
  List<FriendRequest> get pendingIncoming =>
      _friendRequests.where((r) => r.isIncoming && r.status == FriendRequestStatus.pending).toList();

  /// Outgoing requests sent by the user.
  List<FriendRequest> get pendingOutgoing =>
      _friendRequests.where((r) => !r.isIncoming && r.status == FriendRequestStatus.pending).toList();

  /// Load contacts and friend requests from local storage.
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

    final requestsJson = prefs.getString(_requestsKey);
    if (requestsJson != null) {
      try {
        final list = jsonDecode(requestsJson) as List<dynamic>;
        _friendRequests = list
            .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('[ContactService] Failed to load friend requests: $e');
        _friendRequests = [];
      }
    }

    notifyListeners();
  }

  /// Send a friend request to add a new contact.
  /// Creates an outgoing request. The contact becomes confirmed only
  /// when the other party also adds us (or we receive and accept their request).
  Future<void> sendFriendRequest(
    String publicKey,
    String displayName, {
    required String myPublicKey,
    required String myDisplayName,
  }) async {
    // Check if already a contact
    if (_contacts.any((c) => c.publicKey == publicKey)) return;

    // Check if there's already a pending request
    final existing = _friendRequests.indexWhere(
      (r) => r.fromPublicKey == publicKey || r.toPublicKey == publicKey,
    );

    if (existing != -1) {
      final req = _friendRequests[existing];
      // If they already sent us a request, auto-accept (mutual add)
      if (req.isIncoming && req.status == FriendRequestStatus.pending) {
        await acceptFriendRequest(req.id, displayName: displayName);
        return;
      }
      // Already have an outgoing request
      if (!req.isIncoming) return;
    }

    // Create outgoing friend request
    final request = FriendRequest(
      id: const Uuid().v4(),
      fromPublicKey: myPublicKey,
      fromDisplayName: myDisplayName,
      toPublicKey: publicKey,
      status: FriendRequestStatus.pending,
      createdAt: DateTime.now(),
      isIncoming: false,
    );

    _friendRequests.add(request);
    await _persistRequests();
    notifyListeners();

    debugPrint('[ContactService] Friend request sent to $publicKey');
  }

  /// Receive an incoming friend request (called when we scan/receive their payload).
  Future<void> receiveIncomingRequest(
    String fromPublicKey,
    String fromDisplayName, {
    required String myPublicKey,
  }) async {
    // Check if already a contact
    if (_contacts.any((c) => c.publicKey == fromPublicKey)) return;

    // Check if we already sent them a request — auto-complete handshake
    final existingOutgoing = _friendRequests.indexWhere(
      (r) => !r.isIncoming && r.toPublicKey == fromPublicKey && r.status == FriendRequestStatus.pending,
    );

    if (existingOutgoing != -1) {
      // Both parties added each other — complete the handshake
      _friendRequests[existingOutgoing] = _friendRequests[existingOutgoing].copyWith(
        status: FriendRequestStatus.accepted,
      );
      await _addConfirmedContact(fromPublicKey, fromDisplayName);
      await _persistRequests();
      notifyListeners();
      debugPrint('[ContactService] Handshake completed with $fromPublicKey');
      return;
    }

    // Check for duplicate incoming
    if (_friendRequests.any((r) => r.isIncoming && r.fromPublicKey == fromPublicKey)) return;

    // Create incoming request
    final request = FriendRequest(
      id: const Uuid().v4(),
      fromPublicKey: fromPublicKey,
      fromDisplayName: fromDisplayName,
      toPublicKey: myPublicKey,
      status: FriendRequestStatus.pending,
      createdAt: DateTime.now(),
      isIncoming: true,
    );

    _friendRequests.add(request);
    await _persistRequests();
    notifyListeners();

    debugPrint('[ContactService] Incoming friend request from $fromPublicKey');
  }

  /// Accept a friend request — adds the person as a confirmed contact.
  Future<void> acceptFriendRequest(String requestId, {String? displayName}) async {
    final index = _friendRequests.indexWhere((r) => r.id == requestId);
    if (index == -1) return;

    final request = _friendRequests[index];
    _friendRequests[index] = request.copyWith(status: FriendRequestStatus.accepted);

    final contactKey = request.isIncoming ? request.fromPublicKey : request.toPublicKey;
    final contactName = displayName ??
        (request.isIncoming ? request.fromDisplayName : '');

    await _addConfirmedContact(contactKey, contactName);
    await _persistRequests();
    notifyListeners();
  }

  /// Reject a friend request.
  Future<void> rejectFriendRequest(String requestId) async {
    final index = _friendRequests.indexWhere((r) => r.id == requestId);
    if (index == -1) return;

    _friendRequests[index] = _friendRequests[index].copyWith(
      status: FriendRequestStatus.rejected,
    );
    await _persistRequests();
    notifyListeners();
  }

  /// Legacy direct add (bypasses handshake — used for backward compat).
  Future<void> addContact(String publicKey, String displayName) async {
    await _addConfirmedContact(publicKey, displayName);
  }

  Future<void> _addConfirmedContact(String publicKey, String displayName) async {
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

  Future<void> removeContact(String publicKey) async {
    _contacts.removeWhere((c) => c.publicKey == publicKey);
    _friendRequests.removeWhere(
      (r) => r.fromPublicKey == publicKey || r.toPublicKey == publicKey,
    );
    await _persistContacts();
    await _persistRequests();
    notifyListeners();
  }

  Future<void> toggleBlock(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(blocked: !_contacts[index].blocked);
    await _persistContacts();
    notifyListeners();
  }

  Future<void> toggleMute(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(muted: !_contacts[index].muted);
    await _persistContacts();
    notifyListeners();
  }

  Future<void> toggleFollow(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(following: !_contacts[index].following);
    await _persistContacts();
    notifyListeners();
  }

  Future<void> toggleCloseFriend(String publicKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(closeFriend: !_contacts[index].closeFriend);
    await _persistContacts();
    notifyListeners();
  }

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

  Future<void> _persistRequests() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_friendRequests.map((r) => r.toJson()).toList());
    await prefs.setString(_requestsKey, json);
  }
}
