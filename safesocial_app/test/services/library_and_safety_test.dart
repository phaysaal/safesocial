import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/safety_number.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/secure_store.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  group('safety number', () {
    test('both sides compute the same number from the same keys', () {
      final mine = SafetyNumber.compute(
        myIdentity: 'aa' * 32,
        myDeviceKeys: ['11' * 32, '22' * 32],
        peerIdentity: 'bb' * 32,
        peerDeviceKeys: ['33' * 32],
      );
      final theirs = SafetyNumber.compute(
        myIdentity: 'bb' * 32,
        myDeviceKeys: ['33' * 32],
        peerIdentity: 'aa' * 32,
        peerDeviceKeys: ['22' * 32, '11' * 32],
      );
      expect(mine, theirs);
      expect(mine.replaceAll(' ', ''), matches(RegExp(r'^\d{60}$')));
      expect(mine.split(' '), hasLength(12));
    });

    test('a swapped device key changes the number', () {
      final honest = SafetyNumber.compute(
          myIdentity: 'aa' * 32, myDeviceKeys: ['11' * 32], peerIdentity: 'bb' * 32, peerDeviceKeys: ['33' * 32]);
      final swapped = SafetyNumber.compute(
          myIdentity: 'aa' * 32, myDeviceKeys: ['11' * 32], peerIdentity: 'bb' * 32, peerDeviceKeys: ['44' * 32]);
      expect(honest, isNot(swapped));
    });

    test('an added device changes the number, so verification is re-asked', () {
      final before = SafetyNumber.compute(
          myIdentity: 'aa' * 32, myDeviceKeys: ['11' * 32], peerIdentity: 'bb' * 32, peerDeviceKeys: ['33' * 32]);
      final after = SafetyNumber.compute(
          myIdentity: 'aa' * 32, myDeviceKeys: ['11' * 32], peerIdentity: 'bb' * 32, peerDeviceKeys: ['33' * 32, '55' * 32]);
      expect(before, isNot(after));
    });

    test('the QR payload round-trips and rejects anything else', () {
      final number = SafetyNumber.compute(
          myIdentity: 'aa' * 32, myDeviceKeys: ['11' * 32], peerIdentity: 'bb' * 32, peerDeviceKeys: ['33' * 32]);
      expect(SafetyNumber.fromQr(SafetyNumber.qrPayload(number)), number);
      expect(SafetyNumber.fromQr('spheres://add?key=x'), isNull);
      expect(SafetyNumber.fromQr('spheres-verify:12345'), isNull);
    });
  });

  group('library: archive and member mute', () {
    test('archiving a chat hides it without touching anything else', () async {
      final lib = LibraryService();
      await lib.toggleArchiveChat('bob');
      expect(lib.isChatArchived('bob'), isTrue);
      expect(lib.archivedChatCount, 1);
      expect(lib.isPinned('bob'), isFalse);

      final again = LibraryService();
      await again.load();
      expect(again.isChatArchived('bob'), isTrue);

      await again.toggleArchiveChat('bob');
      expect(again.isChatArchived('bob'), isFalse);
    });

    test('archiving a sphere is separate from muting it', () async {
      final lib = LibraryService();
      await lib.toggleArchiveSphere('s1');
      expect(lib.isSphereArchived('s1'), isTrue);
      expect(lib.isMuted('s1'), isFalse);
    });

    test('a member muted in one sphere is not muted in another, and it persists',
        () async {
      final lib = LibraryService();
      await lib.toggleMuteMember('s1', 'carol');
      expect(lib.isMemberMuted('s1', 'carol'), isTrue);
      expect(lib.isMemberMuted('s2', 'carol'), isFalse);
      expect(lib.mutedMembersIn('s1'), {'carol'});

      final again = LibraryService();
      await again.load();
      expect(again.isMemberMuted('s1', 'carol'), isTrue);

      await again.toggleMuteMember('s1', 'carol');
      expect(again.mutedMembersIn('s1'), isEmpty);
    });
  });
}
