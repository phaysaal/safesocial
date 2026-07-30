import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'secure_store.dart';

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
  String? _myExchangeKey;

  List<Contact> get contacts => List.unmodifiable(_contacts);

  /// The X25519 key we know for a contact, or null if we have not learned it.
  ///
  /// Wired into ChatService so messages can be sealed without ChatService
  /// depending on this service.
  String? exchangeKeyFor(String identityKey) {
    for (final contact in _contacts) {
      if (contact.publicKey == identityKey) return contact.keyExchangePublicKey;
    }
    return null;
  }

  void setMyInfo(String publicKey, String displayName,
      {String? exchangeKey, String? secretKey}) {
    _myPublicKey = publicKey;
    _myDisplayName = displayName;
    if (exchangeKey != null) _myExchangeKey = exchangeKey;
    if (secretKey != null) _mySecretKey = secretKey;
  }

  String? _mySecretKey;
  Timer? _inboxTimer;

  /// Called when a contact becomes usable — i.e. we know their X25519 key and
  /// can therefore open encrypted channels to them.
  ///
  /// Adding a contact used to wire chat and calls at the one call site that
  /// happened to remember to, and nothing at all when the contact arrived via
  /// an inbound handshake. So the person who scanned got a working contact and
  /// the person who was scanned got nothing.
  void Function(String publicKey)? onContactReady;

  /// Drain our handshake inbox.
  ///
  /// Handshakes are the one channel that cannot use a shared secret — a
  /// stranger has none with us — so the inbox address is our identity key.
  /// Writes to it are open, reads are signed with the identity secret, so only
  /// we can see who asked.
  ///
  /// Previously the inbound room was joined only while *sending* a handshake,
  /// so an incoming request could not be received unless we happened to have
  /// sent one first in the same session.
  /// Check the inbox on a timer.
  ///
  /// There is no live channel for handshakes — a stranger has no shared secret
  /// to open one with — so the inbox has to be polled. It was previously read
  /// exactly once, during startup wiring, which meant a request only arrived
  /// if the recipient happened to launch the app afterwards. Two people adding
  /// each other with both apps open, which is the normal case, never worked.
  void startInboxPolling({Duration interval = const Duration(seconds: 20)}) {
    _inboxTimer?.cancel();
    _inboxTimer = Timer.periodic(interval, (_) => listenForHandshakes());
    listenForHandshakes();
  }

  void stopInboxPolling() {
    _inboxTimer?.cancel();
    _inboxTimer = null;
  }

  @override
  void dispose() {
    stopInboxPolling();
    super.dispose();
  }

  Future<void> listenForHandshakes() async {
    final publicKey = _myPublicKey;
    final secretKey = _mySecretKey;
    if (publicKey == null || secretKey == null) return;

    final payloads = await _handshakeRelay.syncInbox(publicKey, secretKey);
    for (final payload in payloads) {
      await handleIncomingHandshake(publicKey, payload);
    }

    await _backfillMissingExchangeKeys();
  }

  /// Fetch prekeys for contacts we cannot yet encrypt to.
  ///
  /// A contact added before the other side published its bundle has no
  /// exchange key, and every send to them fails with NoSessionException —
  /// which the callers only log. Retrying here is what turns that from
  /// permanent into temporary.
  Future<void> _backfillMissingExchangeKeys() async {
    for (final contact in _contacts.toList()) {
      if (contact.keyExchangePublicKey != null) continue;

      final prekeyStr = await _handshakeRelay.fetchPrekey(contact.publicKey);
      if (prekeyStr == null) continue;

      try {
        final envelope = jsonDecode(prekeyStr) as Map<String, dynamic>;
        final bundle = envelope['bundle'];
        if (bundle is Map<String, dynamic> &&
            _prekeyIsAuthentic(
                contact.publicKey, bundle, envelope['signature']) &&
            bundle['keyExchangePublicKey'] is String) {
          await setExchangeKey(
              contact.publicKey, bundle['keyExchangePublicKey'] as String);
          DebugLogService().success(
              'Contacts', 'Can now encrypt to ${contact.displayName}');
        }
      } catch (_) {
        // Try again on the next tick.
      }
    }
  }

  /// Add a contact and send a handshake request.
  Future<void> addContact(String publicKey, String displayName,
      {bool isPending = false, String? keyExchangePublicKey}) async {
    if (_contacts.any((c) => c.publicKey == publicKey)) return;

    // Try to fetch their profile from the relay for the latest name and their
    // key exchange key.
    String finalName = displayName;
    String? exchangeKey = keyExchangePublicKey;
    try {
      // Only fetch when we do not already have the key — a scanned invite and
      // an inbound handshake both carry it, and the round trip would only add
      // a way for adding a contact to fail.
      final prekeyStr = exchangeKey != null
          ? null
          // Only the key bundle is public. The display name arrives through
          // the handshake instead: publishing it at an unauthenticated
          // endpoint made every user's name readable by anyone with a key.
          : await _handshakeRelay.fetchPrekey(publicKey);
      if (prekeyStr != null) {
        final envelope = jsonDecode(prekeyStr) as Map<String, dynamic>;
        final bundle = envelope['bundle'];
        // Verify the bundle is signed by the identity it claims, so a relay
        // operator cannot swap in their own exchange key.
        if (bundle is Map<String, dynamic> &&
            _prekeyIsAuthentic(publicKey, bundle, envelope['signature'])) {
          if (exchangeKey == null && bundle['keyExchangePublicKey'] is String) {
            exchangeKey = bundle['keyExchangePublicKey'] as String;
          }
        }
      }
    } catch (_) {
      // Fallback to provided name
    }

    final contact = Contact(
      publicKey: publicKey,
      keyExchangePublicKey: exchangeKey,
      displayName: finalName,
      addedAt: DateTime.now(),
      isPending: isPending,
    );

    _contacts.add(contact);
    await _persistContacts();
    notifyListeners();

    if (contact.keyExchangePublicKey != null) {
      onContactReady?.call(publicKey);
    }

    // Send handshake via relay so they add us back
    if (_myPublicKey != null && !isPending) {
      _sendHandshake(publicKey, 'contact_request');
    }
  }

  /// Handle incoming handshake from another peer.
  Future<void> handleIncomingHandshake(String senderKey, String data) async {
    try {
      final json = jsonDecode(data);
      final type = json['type'];
      final name = json['name'] ?? 'Unknown';
      final publicKey = json['publicKey'];
      final exchangeKey = json['keyExchangePublicKey'];

      if (publicKey is! String || publicKey.isEmpty) {
        DebugLogService().warn('Contacts', 'Handshake without a public key');
        return;
      }

      if (type == 'contact_request') {
        DebugLogService().info('Contacts', 'Incoming contact request from $name');
        // Automatically add them as a pending contact
        await addContact(publicKey, name,
            isPending: true,
            keyExchangePublicKey: exchangeKey is String ? exchangeKey : null);
        // Send back our info
        _sendHandshake(publicKey, 'contact_accept');
      } else if (type == 'contact_accept') {
        DebugLogService().success('Contacts', '$name accepted your request');
        _updateContactInfo(publicKey, name, isPending: false);
        if (exchangeKey is String) {
          await setExchangeKey(publicKey, exchangeKey);
        }
      }
    } catch (e) {
      DebugLogService().error('Contacts', 'Handshake error: $e');
    }
  }

  /// Check a prekey bundle really was signed by the identity it names.
  ///
  /// Without this the relay could hand out its own X25519 key for any contact
  /// and sit in the middle of every conversation with them.
  bool _prekeyIsAuthentic(
    String identityPublicKeyHex,
    Map<String, dynamic> bundle,
    dynamic signatureHex,
  ) {
    if (signatureHex is! String) return false;
    if (bundle['publicKey'] != identityPublicKeyHex) return false;
    try {
      return ed.verify(
        ed.PublicKey(hex.decode(identityPublicKeyHex)),
        utf8.encode(jsonEncode(bundle)),
        Uint8List.fromList(hex.decode(signatureHex)),
      );
    } catch (_) {
      return false;
    }
  }

  /// Record a contact's X25519 key once we learn it.
  Future<void> setExchangeKey(String publicKey, String exchangeKey) async {
    final index = _contacts.indexWhere((c) => c.publicKey == publicKey);
    if (index == -1) return;
    if (_contacts[index].keyExchangePublicKey == exchangeKey) return;

    _contacts[index] =
        _contacts[index].copyWith(keyExchangePublicKey: exchangeKey);
    await _persistContacts();
    notifyListeners();

    // Only now can anything be encrypted to them.
    onContactReady?.call(publicKey);
  }

  void _sendHandshake(String targetKey, String type) {
    final payload = jsonEncode({
      'type': type,
      'name': _myDisplayName ?? 'User',
      'publicKey': _myPublicKey,
      'keyExchangePublicKey': _myExchangeKey,
    });
    
    _handshakeRelay.postToInbox(targetKey, payload);
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
    final prefs = SecureStore.instance;
    final json = await prefs.getString(_prefsContactsKey);
    if (json != null) {
      final List<dynamic> list = jsonDecode(json);
      _contacts.clear();
      _contacts.addAll(list.map((e) => Contact.fromJson(e)));
    }
    notifyListeners();
  }

  Future<void> _persistContacts() async {
    final prefs = SecureStore.instance;
    await prefs.setString(_prefsContactsKey, jsonEncode(_contacts.map((e) => e.toJson()).toList()));
  }
}
