import 'crypto/session_manager.dart';
import 'services/album_service.dart';
import 'services/sphere_info_service.dart';
import 'services/call_service.dart';
import 'services/chat_service.dart';
import 'services/contact_service.dart';
import 'services/debug_log_service.dart';
import 'services/feed_service.dart';
import 'services/identity_service.dart';
import 'services/library_service.dart';
import 'services/media_service.dart';
import 'services/profile_sync.dart';
import 'services/location_provider.dart';
import 'services/sphere_migration.dart';
import 'dart:async';
import 'dart:convert';

import 'services/sphere_chat_service.dart';
import 'services/sphere_sync_service.dart';
import 'services/sphere_service.dart';
import 'services/outbox_service.dart';
import 'services/relay_service.dart';
import 'services/send_alarms.dart';

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
  required SphereInfoService sphereInfoService,
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

  await sessionManager.configure(
    keyExchangeKeyPair: exchangeKeyPair,
    identityKey: publicKey,
    identitySecret: secretKey,
  );
  await sessionManager.load();

  // Every device of everyone we seal to: contacts from their signed lists,
  // ourselves from our own. One session per pair of devices.
  sessionManager.deviceResolver = (identityKey) => identityKey == publicKey
      ? identityService.deviceExchangeKeys
      : contactService.devicesOf(identityKey);

  contactService.setMyInfo(
    publicKey,
    identityService.currentIdentity!.displayName,
    exchangeKey: identityService.exchangePublicKey,
    secretKey: secretKey,
  );
  contactService.myDevices = () => identityService.deviceList?.toJson();

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

  // Names for notifications. A key is never shown to the user.
  String nameFor(String key) {
    final contact = contactService.getContact(key);
    if (contact != null) return contact.displayName;
    return 'Someone in your spheres';
  }
  chatService.resolveName = nameFor;
  chatService.positionProvider = GeoLocationProvider.current;
  sphereChatService.resolveName = nameFor;
  feedService.resolveName = nameFor;

  // Federation: a contact on another relay is sent to there. Channel keys on
  // the chat, feed and call channels are contact keys; anything else (device
  // pairing) resolves to null and stays on our relay.
  RelayHub.instance.peerHostResolver = contactService.relayHostFor;

  Future<void> Function() profileSyncOwnDevices = () async {};
  // Devices. A new signed list from a contact updates their entry; one from
  // our own other device updates ours. Changes we make here are published and
  // announced, and the channels to our own devices follow the list.
  chatService.onDeviceList = (from, json) async {
    if (from == publicKey) {
      if (await identityService.adoptDeviceList(json)) {
        // A device we did not know of may hold a profile with no picture.
        unawaited(profileSyncOwnDevices());
      }
    } else {
      await contactService.applyDeviceList(from, json);
    }
  };
  chatService.onContactSync = contactService.applyContactSync;
  chatService.onProfile = contactService.applyProfile;
  contactService.materialiseMedia = MediaService.decodeAndSaveImage;
  // Our profile goes to contacts as a sealed message, never to the public
  // bundle. The avatar travels as an encrypted blob like any photo. Each
  // contact gets it when it differs from what they were last sent: on every
  // edit, when they are added, and at every start.
  final me = identityService.publicKey;
  final profileSync = ProfileSync(
    profile: () => identityService.currentIdentity,
    peers: () => [
      for (final c in contactService.contacts)
        if (!c.blocked && c.keyExchangePublicKey != null) c.publicKey,
    ],
    // The spheres a contact shares with us decide which fields they get.
    sharedSpheres: (peer) => {
      for (final s in sphereService.spheres)
        if (s.contains(peer) && me != null && s.contains(me)) s.id,
    },
    restricted: (peer) => contactService.getContact(peer)?.restricted ?? false,
    upload: MediaService.prepareForRelay,
    send: chatService.sendProfileTo,
    sendOwn: (everything) => chatService.sendToOwnDevices('profile', jsonEncode(everything)),
    everything: identityService.profileForOwnDevices,
    ownDevices: () => identityService.deviceList?.devices.map((d) => d.deviceId) ?? const [],
  );
  identityService.onProfileChanged = (_) => profileSync.sync(onlyChanged: false);
  // A send the relay did not take is owed; the moment that contact's channel
  // comes up (a start without network, a reconnect) it goes, not at the next
  // start only.
  chatService.onPeerConnected = (peer) => unawaited(profileSync.sync(to: [peer]).catchError((Object e) {
        DebugLogService().error('Wiring', 'Could not send our profile to $peer: $e');
        return const <String>[];
      }));
  chatService.onHeardFrom = (peer) => unawaited(contactService.heardFrom(peer));
  profileSyncOwnDevices = () => profileSync.sync().then((_) {}).catchError((Object e) {
        DebugLogService().error('Wiring', 'Could not send our profile to our devices: $e');
      });
  chatService.onOwnProfile = (json) =>
      identityService.adoptFromOwnDevice(json, materialise: MediaService.decodeAndSaveImage);
  // A temporary picture whose time ran out while the app was closed, and a
  // note whose day is over.
  unawaited(identityService.expireTemporaryAvatar());
  unawaited(identityService.expireNote());
  // Invite links: a request lands in our inbox; approving makes them a
  // contact and a member in one step.
  contactService.onJoinRequest = ({required sphereId, required token, required requester}) =>
      sphereService.recordJoinRequest(sphereId: sphereId, token: token, requester: requester);
  sphereService.onBeforeApproveJoin = (requester) async {
    final key = requester['publicKey'] as String;
    await contactService.addContact(
      key,
      requester['name'] as String? ?? 'New member',
      keyExchangePublicKey: requester['keyExchangePublicKey'] as String?,
      relayHost: requester['relay'] as String?,
      announce: false,
    );
    if (requester['devices'] != null) {
      await contactService.applyDeviceList(key, requester['devices']);
    }
    await contactService.acceptSilently(key);
  };
  feedService.hidesText = libraryService.hidesText;
  sphereChatService.hidesText = libraryService.hidesText;
  feedService.membersOf = (sphereId) =>
      sphereService.sphere(sphereId)?.members.map((m) => m.identityKey).toList() ?? const [];
  callService.onGroupCallStarted = (groupId, members, type) async {
    try {
      await sphereChatService.sendMessage(groupId, 'Started a ${type.name} call',
          kind: 'call', payload: {'group_id': groupId, 'type': type.name});
    } catch (_) {}
  };
  await callService.loadLog();
  chatService.onUnknownDevice = contactService.refreshBundle;
  contactService.onContactsChanged = (op) async {
    await chatService.sendToOwnDevices('contacts', jsonEncode(op));
    // Restricting someone, or releasing them, changes the cut of our profile
    // they get. Send it now rather than at the next start: until then they
    // held the fuller copy (seen with three phones, 12 October 2026).
    final key = (op['contact'] as Map?)?['publicKey'];
    if (op['op'] == 'upsert' && key is String) {
      unawaited(profileSync.sync(to: [key]).catchError((Object e) {
        DebugLogService().error('Wiring', 'Could not send our profile to $key: $e');
        return const <String>[];
      }));
    }
  };
  chatService.contactKeys = () => [
        for (final c in contactService.contacts)
          if (!c.blocked && !c.isPending) c.publicKey,
      ];
  identityService.onDeviceListChanged = (list) {
    unawaited(identityService.publishProfileToRelay(relayService));
    unawaited(chatService.broadcastDeviceList(list.toJson()));
    unawaited(chatService.connectOwnDevices());
    unawaited(feedService.connectOwnDevices());
    // The device just linked holds our words from the backup but none of
    // our pictures; the list changing is what makes the profile due again.
    unawaited(profileSyncOwnDevices());
  };
  callService.setMyInfo(publicKey, secretKey);
  callService.resolveName = (key) => contactService.getContact(key)?.displayName;
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
  chatService.wantsOriginalQuality = () => libraryService.originalQualityMedia;
  chatService.isIgnored = libraryService.isChatIgnored;
  unawaited(chatService.sendDueScheduled());
  // The wake alarm for scheduled sends follows the schedule, and is re-set
  // at every start because alarms do not survive a reboot.
  Future<void> resyncAlarm() => SendAlarms.resync(chatService, feedService);
  chatService.onScheduleChanged = () => unawaited(resyncAlarm());
  feedService.onScheduleChanged = () => unawaited(resyncAlarm());
  SendAlarms.onDue = () async {
    await chatService.sendDueScheduled();
    await feedService.publishDueDrafts();
  };
  unawaited(resyncAlarm());
  feedService.onMissingKey = (sphereId, epoch) => sphereService.requestKey(sphereId, epoch: epoch);

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
  sphereSyncService.sendToPeer = feedService.sendSealedToAllDevices;
  sphereSyncService.onRecovered = feedService.handleRecovered;
  feedService.archiveEnvelope = sphereSyncService.remember;
  feedService.onSyncDigest = sphereSyncService.handleDigest;
  feedService.onSyncItems = sphereSyncService.handleItems;
  await sphereSyncService.prune();

  // Rules, topics, guides, badges, suspensions and admin automation: one
  // signed item per sphere from an admin, enforced locally from the copy held.
  await sphereInfoService.load();
  sphereInfoService.publish = feedService.publishSphereItem;
  sphereInfoService.keywordsFor = libraryService.adminKeywords;
  sphereInfoService.muteLocally = (sphereId, member) async {
    if (!libraryService.isMemberMuted(sphereId, member)) {
      await libraryService.toggleMuteMember(sphereId, member);
    }
  };
  sphereInfoService.isMutedLocally = libraryService.isMemberMuted;
  feedService.onSphereInfo = sphereInfoService.handleIncoming;
  feedService.isSuspended = sphereInfoService.isSuspended;
  feedService.onSphereText = (sphereId, author, text, route) =>
      sphereInfoService.keywordAlert(sphereId, author, text, route: route);
  feedService.onReportsFor = (sphereId, author, count) async {
    await sphereInfoService.reportsReached(sphereId, author, count);
  };
  sphereChatService.isSuspended = sphereInfoService.isSuspended;
  sphereChatService.onSphereText = (sphereId, author, text, route) =>
      sphereInfoService.keywordAlert(sphereId, author, text, route: route);
  // Seen on hardware: the welcome post went out at approval and the newcomer's
  // device dropped it as "not a member", because the invitation was still
  // unanswered there. A sync right after joining brings it, and anything else
  // the sphere already holds, without waiting for the next scheduled one.
  sphereService.onJoined = (sphereId) => unawaited(sphereSyncService.syncSphere(sphereId).catchError((Object e) {
        DebugLogService().error('Wiring', 'Could not sync "$sphereId" after joining: $e');
      }));
  sphereService.onMemberJoined = (sphereId, publicKey, name) async {
    // The rules, topics and welcome line again, sealed under the epoch the
    // newcomer holds; the copy sent earlier was sealed before their time.
    await sphereInfoService.republish(sphereId);
    final welcome = sphereInfoService.infoFor(sphereId).welcome;
    final sphere = sphereService.sphere(sphereId);
    if (welcome.isEmpty || sphere == null) return;
    await feedService.createPost(
      welcome.replaceAll('{name}', name),
      sphereId: sphereId,
      audienceMembers: sphere.members.map((m) => m.identityKey).toList(),
      authorName: identityService.currentIdentity?.displayName ?? 'You',
    );
  };
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
  feedService.mutedSpheres = () => libraryService.quietSpheres;
  feedService.mutedMembers = libraryService.mutedMembersIn;
  feedService.quietAuthors = contactService.quietKeys;
  feedService.unfollowedAuthors = contactService.unfollowedKeys;
  feedService.dataSaver = () => libraryService.dataSaver;
  sphereChatService.mutedMembers = libraryService.mutedMembersIn;
  sphereChatService.sendReadReceipts = () => chatService.sendReadReceipts;
  Timer.periodic(const Duration(seconds: 30), (_) => sphereChatService.sweepExpired());
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
    // Someone added after our picture was chosen would otherwise see an
    // initial until our next edit.
    unawaited(profileSync.sync(to: [key]).catchError((Object e) {
      DebugLogService().error('Wiring', 'Could not send our profile to $key: $e');
      return const <String>[];
    }));
  }

  contactService.onContactReady = wireContact;
  contactService.onContactRemoved = (key) => unawaited(profileSync.forget(key));
  // The feed needs our key before it can open anything, including the channel
  // to our own other devices; opening that first left every post after a
  // restart on this device only.
  feedService.initSync(publicKey, secretKey, contactService.contacts);
  // Members of our spheres who are not contacts get a feed channel too, now
  // and whenever a membership changes.
  await feedService.connectSphereMembers();
  sphereService.addListener(() => unawaited(feedService.connectSphereMembers()));
  await chatService.connectOwnDevices();
  await feedService.connectOwnDevices();

  for (final contact in contactService.contacts) {
    if (contact.blocked) continue;
    chatService.connectRelay(contact.publicKey);
    callService.connectSignaling(contact.publicKey);
  }

  // Polls the handshake inbox and backfills any missing exchange keys.
  contactService.startInboxPolling();
  // Anyone whose copy of our profile is out of date (never sent, or they
  // now share a sphere with us and may see more).
  unawaited(profileSync.sync().catchError((Object e) {
    DebugLogService().error('Wiring', 'Could not bring profiles up to date: $e');
    return const <String>[];
  }));

  albumService.initSync(publicKey, secretKey);

  DebugLogService().success(
    'Wiring',
    'Identity wired for ${contactService.contacts.length} contacts',
  );
}
