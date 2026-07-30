import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/contact.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Found by running two emulators against the live relay: Alice posted to a
/// sphere Bob was in, and it never appeared on Bob's home screen.
///
/// The cause was one line. `initSync` kept the caller's list, and every caller
/// passes `ContactService.contacts`, which is `List.unmodifiable`. So
/// `connectContact` — the method whose entire job is to open a feed channel for
/// someone added after launch — threw before it could open anything.
///
/// It failed quietly in two directions at once. The feed channel never opened
/// on either device, and because the exception escaped into `addContact`, the
/// inbound-handshake path never got as far as sending its reply.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  Contact contact(String key, {bool blocked = false}) => Contact(
        publicKey: key,
        displayName: 'Peer $key',
        addedAt: DateTime(2026),
        blocked: blocked,
      );

  test('a contact added after launch can be connected', () async {
    final feed = FeedService();
    // Exactly what app_wiring passes: an unmodifiable view.
    feed.initSync('me', 'secret', List.unmodifiable([contact('a')]));

    // Threw "Cannot add to an unmodifiable list" before the fix.
    await feed.connectContact(contact('b'));
  });

  test('the same contact twice is not added twice', () async {
    final feed = FeedService();
    feed.initSync('me', 'secret', List.unmodifiable(<Contact>[]));

    await feed.connectContact(contact('a'));
    await feed.connectContact(contact('a'));
  });

  test('connecting works when launch had no contacts at all', () async {
    // The first-run case: onboard, then add someone. Const-empty lists are
    // unmodifiable too, so this is the same trap.
    final feed = FeedService();
    feed.initSync('me', 'secret', const []);

    await feed.connectContact(contact('a'));
  });

  test('ContactService still hands out a list callers cannot mutate', () async {
    // The fix belongs in the consumer, not here — this guarantee is why the
    // service can expose its contacts at all.
    final contacts = ContactService();
    await contacts.addContact('a' * 64, 'Alice');

    expect(() => contacts.contacts.add(contact('b')), throwsUnsupportedError);
  });
}
