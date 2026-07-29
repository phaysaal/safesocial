import 'crypto/session_manager.dart';
import 'services/album_service.dart';
import 'services/call_service.dart';
import 'services/chat_service.dart';
import 'services/contact_service.dart';
import 'services/debug_log_service.dart';
import 'services/feed_service.dart';
import 'services/group_service.dart';
import 'services/identity_service.dart';

/// Connect an identity to every service that needs it.
///
/// This lives outside `main.dart` because it has to run in two places: at
/// startup for an already-onboarded user, and immediately after onboarding.
/// Previously it existed only in `main()`, so during the first session after
/// signup no service knew the identity — handshakes never sent, relay connects
/// were no-ops, and creating a group crashed on a null secret key. Everything
/// only started working after an app restart.
Future<void> wireIdentity({
  required IdentityService identityService,
  required SessionManager sessionManager,
  required ContactService contactService,
  required ChatService chatService,
  required CallService callService,
  required FeedService feedService,
  required GroupService groupService,
  required AlbumService albumService,
}) async {
  if (!identityService.isOnboarded) return;

  final publicKey = identityService.publicKey!;
  final secretKey = identityService.secretKey!;
  final exchangeKeyPair = identityService.exchangeKeyPair;

  if (exchangeKeyPair == null) {
    DebugLogService().error(
      'Wiring',
      'No key exchange keypair — messaging stays disabled until one exists',
    );
    return;
  }

  sessionManager.configure(
    keyExchangeKeyPair: exchangeKeyPair,
    identityKey: publicKey,
    identitySecret: secretKey,
  );
  await sessionManager.load();

  contactService.setMyInfo(
    publicKey,
    identityService.currentIdentity!.displayName,
    exchangeKey: identityService.exchangePublicKey,
  );
  await contactService.listenForHandshakes();

  chatService.setMyInfo(
    publicKey,
    secretKey,
    sessions: sessionManager,
    resolveExchangeKey: contactService.exchangeKeyFor,
  );
  callService.setMyInfo(publicKey, secretKey);

  for (final contact in contactService.contacts) {
    if (contact.blocked) continue;
    chatService.connectRelay(contact.publicKey);
    callService.connectSignaling(contact.publicKey);
  }

  feedService.initSync(publicKey, secretKey, contactService.contacts);
  groupService.initSync(publicKey, secretKey);
  albumService.initSync(publicKey, secretKey);

  DebugLogService().success(
    'Wiring',
    'Identity wired for ${contactService.contacts.length} contacts',
  );
}
