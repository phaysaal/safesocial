import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Local storage is what several other protections rest on: forward secrecy is
/// largely theoretical if the plaintext history sits on disk beside the keys,
/// and sphere removal means little if the epoch keys are readable.
void main() {
  late Map<String, String> keystore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    keystore = {};

    // flutter_secure_storage has no in-memory test double; stand in for the
    // platform keystore so these run without a device.
    FlutterSecureStorage.setMockInitialValues(keystore);
    await SecureStore.instance.init();
  });

  test('a stored value is not readable in the raw preferences', () async {
    await SecureStore.instance
        .setString('spheres_contacts', 'Barbara and her phone number');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('spheres_contacts');

    expect(raw, isNotNull);
    expect(raw, isNot(contains('Barbara')));
    expect(raw, startsWith('enc1:'));
  });

  test('it round trips', () async {
    await SecureStore.instance.setString('spheres_feed_posts', '["a","b"]');

    expect(await SecureStore.instance.getString('spheres_feed_posts'),
        '["a","b"]');
  });

  test('message history is encrypted, per conversation', () async {
    await SecureStore.instance.setString('spheres_msgs_abc', 'dinner at eight');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('spheres_msgs_abc'), isNot(contains('dinner')));
    expect(await SecureStore.instance.getString('spheres_msgs_abc'),
        'dinner at eight');
  });

  test('sphere keys are encrypted', () async {
    // These cannot be re-derived, and they are what makes removal meaningful.
    await SecureStore.instance.setString('spheres_keyring_v1', 'secret-keys');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('spheres_keyring_v1'), isNot(contains('secret')));
  });

  test('a value cannot be moved to another key', () async {
    await SecureStore.instance.setString('spheres_msgs_alice', 'for alice');

    final prefs = await SharedPreferences.getInstance();
    final stolen = prefs.getString('spheres_msgs_alice')!;
    await prefs.setString('spheres_msgs_bob', stolen);

    // The key is bound as associated data, so relocating the blob fails.
    expect(await SecureStore.instance.getString('spheres_msgs_bob'), isNull);
  });

  test('a tampered value returns null rather than garbage', () async {
    await SecureStore.instance.setString('spheres_contacts', 'original');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('spheres_contacts')!;
    final parts = raw.substring('enc1:'.length).split(':');
    final ct = base64Decode(parts[1]);
    ct[0] ^= 0x01;
    await prefs.setString(
        'spheres_contacts', 'enc1:${parts[0]}:${base64Encode(ct)}');

    expect(await SecureStore.instance.getString('spheres_contacts'), isNull);
  });

  test('non-sensitive settings stay readable in the clear', () async {
    // Theme and relay host are not secrets, and encrypting them would only
    // add a startup dependency.
    await SecureStore.instance.setString('theme_mode', 'dark');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('existing plaintext is migrated on first run', () async {
    // An install from before encryption.
    SharedPreferences.setMockInitialValues({
      'spheres_contacts': 'Barbara',
      'spheres_msgs_abc': 'old conversation',
      'theme_mode': 'dark',
    });
    FlutterSecureStorage.setMockInitialValues({});

    await SecureStore.instance.init();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('spheres_contacts'), startsWith('enc1:'));
    expect(prefs.getString('spheres_msgs_abc'), isNot(contains('old')));
    expect(prefs.getString('theme_mode'), 'dark');

    // And it is still readable through the store.
    expect(await SecureStore.instance.getString('spheres_contacts'), 'Barbara');
  });

  test('migration runs once', () async {
    await SecureStore.instance.setString('spheres_contacts', 'value');
    final prefs = await SharedPreferences.getInstance();
    final first = prefs.getString('spheres_contacts');

    await SecureStore.instance.init();

    // Re-encrypting an already-encrypted value would corrupt it.
    expect(prefs.getString('spheres_contacts'), first);
    expect(await SecureStore.instance.getString('spheres_contacts'), 'value');
  });

  test('sensitive string lists are encrypted and round trip', () async {
    await SecureStore.instance
        .setStringList('spheres_hidden_posts', ['p1', 'p2']);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('spheres_hidden_posts'), isNot(contains('p1')));
    expect(await SecureStore.instance.getStringList('spheres_hidden_posts'),
        ['p1', 'p2']);
  });

  test('clearing removes the key, so residue is unreadable', () async {
    await SecureStore.instance.setString('spheres_contacts', 'value');
    await SecureStore.instance.clear();

    expect(SecureStore.instance.isReady, isFalse);
  });
}
