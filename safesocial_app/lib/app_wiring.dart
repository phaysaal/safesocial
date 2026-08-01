import 'crypto/session_manager.dart';
import 'services/album_service.dart';
import 'services/call_service.dart';
import 'services/chat_service.dart';
import 'services/contact_service.dart';
import 'services/debug_log_service.dart';
import 'services/feed_service.dart';
import 'services/identity_service.dart';
import 'services/library_service.dart';
import 'services/sphere_migration.dart';
import 'dart:async';

import 'services/sphere_chat_service.dart';
import 'services/sphere_sync_service.dart';
import 'services/sphere_service.dart';
import 'services/outbox_service.dart';
import 'services/relay_service.dart';

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
  required OutboxService outboxService,
  required CallService callService,
  required FeedService feedService,
  required AlbumService albumService,
  required SphereService sphereService,
  required LibraryService libraryService,
  required SphereChatService sphereChatService,
  required SphereSyncService sphereSyncService,
  required FeedOutboxService feedOutboxService,
  required RelayService relayService,
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
    secretKey: secretKey,
  );

  // Republish every launch. This was only done at onboarding, so an identity
  // created before prekeys existed — or one whose first publish failed because
  // the device was offline — never advertised an X25519 key at all. Contacts
  // then could not encrypt to them, and every send failed silently.
  await identityService.publishProfileToRelay(relayService);

  await outboxService.load();
  chatService.setMyInfo(
    publicKey,
    secretKey,
    sessions: sessionManager,
    outbox: outboxService,
    resolveExchangeKey: contactService.exchangeKeyFor,
  );
  outboxService.start();
  await outboxService.pruneCompleted();
  callService.setMyInfo(publicKey, secretKey);
  callService.attachCrypto(sessionManager, contactService.exchangeKeyFor);
  await sphereService.load();
  // After spheres, so threads for spheres we have left can be pruned.
  await sphereChatService.load();
  await sphereChatService.pruneDepartedSpheres();
  sphereService.configure(
    sessions: sessionManager,
    identityKey: publicKey,
    identitySecret: secretKey,
    resolveExchangeKey: contactService.exchangeKeyFor,
    // Recorded in member lists so that everyone in a sphere can reach everyone
    // else, not only whoever invited them.
    myExchangeKey: identityService.exchangePublicKey,
  );
  // Membership changes and sphere keys travel over the pairwise chat channels
  // that already exist, so there is no separate transport to keep alive.
  sphereService.sendToPeer = chatService.sendRawToPeer;

  // Group chat is addressed to the sphere, so it travels the same per-member
  // channels as anything else a sphere sees, and arrives through the feed.
  sphereChatService.configure(identityKey: publicKey);
  // The feed channel, not the chat channel: sphere-sealed content is opened
  // on the receiving side by FeedService. Queued rather than sent directly, so
  // nothing is lost when a member — or our own socket — is briefly away.
  sphereChatService.queueForMember = feedService.queueForMember;

  // The feed queue retries on the feed channel, exactly as the chat queue does
  // on the pairwise one.
  await feedOutboxService.load();
  feedOutboxService.send = feedService.sendSealedToMember;
  feedService.outbox = feedOutboxService;
  feedOutboxService.start();
  await feedOutboxService.pruneCompleted();
  feedService.myDisplayName =
      () => identityService.currentIdentity?.displayName ?? '';
  feedService.blockedKeys = () => contactService.contacts
      .where((c) => c.blocked)
      .map((c) => c.publicKey)
      .toSet();
  sphereChatService.blockedKeys = () => contactService.contacts
      .where((c) => c.blocked)
      .map((c) => c.publicKey)
      .toSet();
  feedService.onSphereMessage = sphereChatService.handleIncoming;

  // Filling in what was missed. The archive keeps sealed envelopes so a member
  // can be handed content by a peer when the relay no longer has it.
  await sphereSyncService.load();
  sphereSyncService.sendToPeer = feedService.sendSealedToMember;
  sphereSyncService.onRecovered = feedService.handleRecovered;
  feedService.archiveEnvelope = sphereSyncService.remember;
  feedService.onSyncDigest = sphereSyncService.handleDigest;
  feedService.onSyncItems = sphereSyncService.handleItems;
  await sphereSyncService.prune();
  // Not immediately: the mailbox sockets are still being established at this
  // point, and a digest sent before there is a route to send it on is simply
  // dropped. Delayed once, then on a timer — cheap when there is nothing to
  // exchange, because a peer with nothing to offer answers with nothing.
  Timer(const Duration(seconds: 20), sphereSyncService.syncAll);
  Timer.periodic(const Duration(minutes: 5), (_) => sphereSyncService.syncAll());
  chatService.onSphereOp = sphereService.handleIncomingOp;

  // One-time conversion of legacy groups and rings. Runs after configure() so
  // the service can mint keys, and is a no-op on later launches.
  await SphereMigration.run(sphereService);

  feedService.attachCrypto(
    sessionManager,
    contactService.exchangeKeyFor,
    spheres: sphereService,
  );
  albumService.attachSpheres(sphereService);
  feedService.mutedSpheres = () => {
        for (final s in sphereService.spheres)
          if (libraryService.isMuted(s.id)) s.id
      };
  feedService.onAlbumItem = albumService.handleSealedItem;
  // Album items leave the same way posts and group messages do: the feed's
  // per-member channels, through the durable queue, archived on the way out so
  // a peer who missed one can be given it later.
  albumService.queueForMember = feedService.queueForMember;

  // One place that opens every channel for a contact, wherever the contact
  // came from: a QR scan, an inbound handshake, or a prekey arriving late.
  void wireContact(String key) {
    final matches = contactService.contacts.where((c) => c.publicKey == key);
    if (matches.isEmpty) return;
    final contact = matches.first;
    if (contact.blocked) return;

    // Each channel is opened independently. They used to run as a bare
    // sequence, so when connectContact threw, chat and call were already up
    // but the feed never connected — and the exception escaped into whatever
    // added the contact, which on the inbound-handshake path meant the reply
    // handshake was never sent either. One broken channel must not take the
    // others, or the caller, down with it.
    void open(String what, void Function() connect) {
      try {
        connect();
      } catch (e) {
        DebugLogService()
            .error('Wiring', 'Could not open the $what channel for $key: $e');
      }
    }

    open('chat', () => chatService.connectRelay(key));
    open('call', () => callService.connectSignaling(key));
    open('feed', () => feedService.connectContact(contact));
  }

  contactService.onContactReady = wireContact;

  for (final contact in contactService.contacts) {
    if (contact.blocked) continue;
    chatService.connectRelay(contact.publicKey);
    callService.connectSignaling(contact.publicKey);
  }

  // Polls the handshake inbox and backfills any missing exchange keys.
  contactService.startInboxPolling();

  feedService.initSync(publicKey, secretKey, contactService.contacts);
  albumService.initSync(publicKey, secretKey);

  DebugLogService().success(
    'Wiring',
    'Identity wired for ${contactService.contacts.length} contacts',
  );
}
