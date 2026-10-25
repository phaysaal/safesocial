# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Spheres is an in-development social network in which no content has a public audience.
Everything is scoped to a *sphere*: a named group with an explicit membership list and its
own encryption key. Identity is an Ed25519 keypair plus an X25519 exchange key. Part of
the SafeSelf umbrella project (Phase 2, after SeeSelf).

**Read `docs/rebuild_plan.md` before making architectural changes.** It is the
authoritative plan, records every decision taken (transport, cryptography, push, video,
TURN), and lists what remains. §12 holds the decisions; §13 is the plan to finish.

## Ground truth about the current build (v0.8.0+, 2026-10)

- **The app is 100% Dart over a Cloudflare Worker relay.** No Veilid, no DHT, no
  peer-to-peer. The Rust crate and `RustCoreService` were deleted; git history has them.
- **Cryptography is real and lives in `lib/crypto/`.** X25519 + HKDF + XChaCha20-Poly1305
  via `cryptography`, Ed25519 via `ed25519_edwards`. Envelopes are version 3 and carry the
  sender's device key. Sessions are per *device pair* (`session_manager.dart`); a person's
  devices are certified by their identity key (`device.dart`) and published in the signed
  prekey bundle. Sealing to a person means one envelope per device, plus copies to our
  own other devices.
- **Transport is one hub socket per client** (`RelayHub` in `relay_service.dart`), with
  mailboxes subscribed over it by signature. Services keep their own `RelayService`
  facades; all share the hub. A publish counts as sent only when the relay's `sent` frame
  comes back. The relay keeps every message until an HTTP drain acknowledges it, and a
  mailbox is shared by both parties, so the hub remembers digests of what it delivered and
  published and a drain acknowledges those without delivering them again. Every plain
  HTTP call goes through `relayHttp`, which moves to the workers.dev name when the custom
  domain does not answer at all. A contact on another relay is reached by a signed HTTP
  post to that relay (federation); the host comes from their bundle.
- **Local storage is encrypted at rest** (`SecureStore`); new sensitive keys must be added
  to its list. Backups (`backup_service.dart`) cover every store except sessions and
  outboxes, and double as the device-link payload.
- **Media:** images re-encoded on pick (engine codec, downscaled, no metadata), and
  editable before sending (`edit_image_screen.dart`: rotate, flip, crop presets, filters,
  text, stickers, drawing; an edit lowers a camera capture's origin score to the edited
  band); a picture whose GPano XMP says it is equirectangular is marked as a 360° view
  (`.pano` sidecar, `payload['pano']` indices on the post) and panned in the viewer; video
  transcoded on-device (`video_transcoder.dart`, platform encoder, no ffmpeg) with
  posters, trimmed and given a chosen cover frame through a `.trim` sidecar applied at
  send time; everything chunked and encrypted (`blob_service.dart`). `MediaThumb`
  renders every reference kind.
- **Media origin score.** Before an image is re-encoded, `ProvenanceScanner` reads what the
  file says about itself (camera EXIF, editing software, date disagreement, XMP and Content
  Credentials marks, PNG generator chunks, file name, dimensions) and produces a
  `MediaProvenance`: a 0–10 score plus signal *codes*. It is written as a `.prov` sidecar
  beside the local file and travels in `Post.provenance` / `Message.provenance`, one entry
  per media ref. Only codes and a sanitised tool name cross the wire; the receiving device
  renders the sentence and always shows the disclaimer. The in-app camera button yields
  10; a maker's own AI mark yields 0. It never looks at pixels and is not a detector.
  Per-chat and per-sphere "blur media until tapped" lives in `LibraryService`.
- **Protected media** (`models/media_protection.dart`): a photo or video posted or sent
  with `payload['protected']` (`{'wm': true}` for a watermark) is shown only in
  `ProtectedMediaScreen`, while two fingers are on the glass and for ten seconds at a
  time (`HoldGate`, pure), blurred otherwise; while shown, one band in three is sharp
  each frame and the rest blurred, rolling down like a CRT scan (`ScanBand`,
  `ProtectedVeil`: the same sharp area every frame, so the brightness never flickers;
  plain under reduce motion), so the eye sees a picture and a camera pointed at the
  screen gets a single frame with one sharp band. Random tiles were tried first on the
  Motorola and read as a boiling shimmer. The
  blob is decrypted in memory (a video into a temporary file deleted on the way out) and
  `_decodePostMedia` / `_decodeMedia` leave it as its reference, so nothing of it is ever
  in the media cache; the sender's inline thumbnail is twelve pixels wide and blurred
  (`MediaService.prepareForRelay(protected:)`). The window carries `FLAG_SECURE` while
  the viewer is up (`ScreenGuard` over the `spheres/screen` channel; Android only, and the
  answer says whether it took, so iOS and tests show "Screenshots cannot be blocked on
  this phone"); the iOS runner reports a screenshot or a recording after the fact and
  the picture hides. Save, share, save-as-sticker, forward (`ChatService.forwardMessage`,
  `SphereChatService.sendMessage(forwarded:)`) and reshare (`reshareAllowed`, the
  composer) are refused; the flag rides outside the signed core, so the receiver refuses
  a reshare of a protected original too. The watermark is the viewer's own name across
  the middle, drawn only while shown, and only when the sender turned it on. Everything
  here is enforced by the viewer's app and the composer says so (`MediaProtection.disclaimer`).
- **Pictures that wait for the people in them** (`models/media_lock.dart`,
  `crypto/sealed_box.dart`): a post with tags and `payload['consent']` is sent with its
  media keys stripped from the references (`BlobRef.isLocked`) and, per picture, the key
  sealed to each tagged person plus one XOR share of it sealed to each
  (`FeedService.lockMedia`, refused up front when a tagged person has no exchange key).
  A tagged person opens the key from their box, so they see what they are asked about,
  and says yes with a `media_release` feed item carrying their share; a release is
  honoured only from someone tagged, and one that arrives before its post waits for it.
  When every share is in, any member joins them back into the key, fills it into the
  reference and fetches. Until then the rest of the sphere, the author aside, sees the
  blurred frame and "Waiting for Al", and holds nothing that opens the blob: this is
  arithmetic, not policy. The sealed box is an ephemeral X25519 key, HKDF and
  XChaCha20-Poly1305, opened with the device's exchange key pair
  (`SessionManager.myKeyExchangeKeyPair`). The locked reference's inline preview is the
  twelve-pixel smear (`MediaService.smearOf`), because the first run on the tablet showed
  "Waiting for Moto" over a perfectly readable preview. Ran between the three phones on
  12 October 2026.
- **Notifications** are built on-device from decrypted content (`notification_service.dart`);
  wakes are content-free through `wake_service.dart` (UnifiedPush on Android, APNs via the
  iOS runner). `main()` has a `--unifiedpush-bg` entry that runs `BackgroundSync` with no UI.
  Two Android flavours (`build.gradle.kts`, dimension `store`): `foss` has no Google code
  and needs a distributor such as ntfy, whose open socket shows a persistent notification;
  `play` adds `org.unifiedpush.android:embedded-fcm-distributor`, which registers with
  Google Play services the way a browser does (the relay's VAPID public key as the sender;
  no Firebase project, no Google SDK, no proprietary code) and shows up as the distributor
  `com.spheres.spheres_app`, named "Google Play services (built in)" in Settings; an
  installed external distributor is preferred over it. The Dart code is the same
  (`appFlavor` tells it which build it is). Google's service refuses an unsigned knock and
  drops one with no bytes, so `WakeService` fetches the relay's VAPID key from `GET /`
  before registering (`RelayService.vapidKey`) and sends the distributor's Web Push keys
  with the endpoint (`WakeKeys`, `registerWake`); the relay signs every knock and, given
  keys, encrypts the word "wake" to them (RFC 8292, RFC 8291, both proven from the
  receiving side in `relay/test`). A relay without `VAPID_*` secrets refuses a Google
  endpoint with 501 and the client says so; a `vapidRequired` refusal from the
  distributor is retried once with a fresh ask. Every `flutter build`/`run` now needs
  `--flavor foss` or `--flavor play`; the GitHub release and CI's reproducibility check
  carry `foss`, `build_release.sh` also makes the `play` app bundle. The Google path ran on
  13 October 2026 on the tablet, the Samsung and the Motorola: a killed app was started by
  Play services and showed the chat notification seven seconds after the knock; the relay
  log put the knock within a second of the publish. The run found three things, all fixed
  with tests. Registrations to the distributor now go one at a time, once per process,
  with one retry on an internal error (`WakeService`): five fired together timed out
  inside Play services' IPC, and the same burst into a process the system had frozen
  overflowed its binder buffer and crashed it with the knock unhandled. And an app that is
  merely off screen now lets its hub socket go after a grace (`BackgroundRest`, fifteen
  seconds; a call keeps it; a wake's window closing off screen releases it at once): on
  the Samsung, Android 16 cut the background app's network a minute after it left the
  screen while its socket still looked alive to the relay, so the relay delivered to that
  socket, counted a listener and never knocked. With the socket gone the relay has nobody
  to talk to and knocks, which is the headless rule applied to the UI. A mailbox
  subscribed while the hub rests waits for the next wake instead of reopening the socket
  (the Samsung went behind its lock screen while services were still subscribing), and
  an app started off screen reads the state it started in, since no change event says so.
- **Calls** get STUN/TURN from the relay (`CallConfig.resolve`); without an operator TURN
  they fall back to public STUN and say so. The operator's coturn runs on the Scaleway
  instance beside ntfy (`turn.spheres.dev`, UDP/TCP 3478 and TLS 5349 with a Let's
  Encrypt certificate Caddy renews; secrets `TURN_SECRET`/`TURN_URLS` on the Worker). A "relay every call through TURN" switch under Call Servers sets the ICE
  policy to relay only; that is how the TURN path was proven on 11 October 2026. A
  call's kind is only how it rang: either side turns its camera (or screen) on in a voice
  call or off in a video call at any time (`CallService.setVideo`). The first picture on a
  connection adds the track and renegotiates (`call_update`, answered by
  `call_update_answer`); after that on and off are a track swap on the same sender plus a
  `call_video` line for the other screen. Offers that cross are settled by key order
  (`isPolite`: the smaller key rolls back, answers, offers again). The screen lays out for
  video when anyone sends a picture (`hasVideo`, `remoteSendsVideo`) and re-assigns its
  renderers when a track joins a stream they already hold (`mediaRevision`,
  `RendererGate.reattach`). A
  sphere call (mesh, everyone rung) starts from the sphere header or the sphere chat bar
  (`screens/spheres/group_call.dart`); a voice note is a direct-chat thing (hold the
  microphone), not yet a sphere-chat one. A sphere chat's attach button offers a photo,
  the camera, a video, a file and a poll.
- **Notes from a call** (`docs/call_notes.md`; off by default, Settings, Network): with
  the person's say-so, their *own* words in a call become notes on the phone. A second
  microphone capture is piped to Android's on-device recogniser (`CallNotes.kt`, Android
  13 and up, channel `spheres/notes`) and each finalised segment goes to one AutoEar v2
  engine session (`android/app/libs/autoear-engine.jar`, pure JVM, rule-based, English
  only); `CallNotesService` starts it when a call connects, stops it when the call ends
  and keeps the notes and summary sealed under the call's log entry
  (`spheres_call_notes_v1`, entries now carry an `id`). A notes button in the call turns
  them on for both phones: `CallService.setNotes` sends a `call_notes` line and the other
  side starts its own (`applyNotesSignal`), each phone noting its own voice and its chip
  saying who began; the setting makes this happen at every connect. When the call ends,
  each phone with notes is asked once whether to send them to the other as a chat message
  (`shareOffer`, `shareText`; the prompt lives in `HomeScreen`). Every note carries the
  clock time it was said (`CallNote.at`, from the engine's offset and when notes began),
  and the message goes as kind `call_notes` with the notes and the span in its payload
  (`sharePayload`, `SharedCallNotes`); the receiving phone matches it to its own record of
  the call by that span, two minutes of slack for clocks (`recordOverlapping`), and the
  notes screen shows both sides as one list in the order things were said
  (`CallNotesService.merge`), theirs labelled with their name and left as sent, ours
  editable. The other party is not recorded;
  the transcript is never stored, logged or passed over the channel. Every note is shown
  as engine-made and uncertain, editable and deletable (`CallNotesScreen`, reached from
  the call history). Where there is no platform code or the phone cannot, the switch says
  why. Integrated on 16 October 2026 at the AutoEar session's request with the owner's
  consent; untested on hardware.
- **Hub identity.** The hub id in the socket URL is minted once per install and kept in
  plain `SharedPreferences`, because a mailbox holds one subscriber slot per hub and a
  fresh id per process filled the slots with dead hubs within a day. The relay evicts
  the oldest subscriber when a mailbox is full rather than refusing the newcomer.
- **Key verification** (`crypto/safety_number.dart`) covers both identity keys and every
  device key; a contact's verified number is stored and a changed key shows a banner.
- **Local organisation** lives in `LibraryService`: saves, stars, pins, mutes, sphere
  snoozes, archives, locked chats, blurred media, hidden words, member notes, stickers,
  data saver, the favourites-only feed. Everything in it stays on the device. Per-contact
  choices live on `Contact`: muted, following, snoozed-until, on a break, restricted,
  favourite. The feed reads `quietAuthors`/`unfollowedAuthors` and the notification
  service `isQuiet`, both from `ContactService`; a restricted contact's profile copy is
  name and picture only (`ProfileSharing.payloadFor(restricted:)`). A quiet contact's
  call still rings. Nothing of this is told to the other person.
- **Message kinds.** `Message.kind` is text, poll, location, contact, video_note, sticker,
  file (any type, uploaded as it is with `name`, `mime` and `size` in the payload, opened
  through the `spheres/files` channel), call_notes (one side's notes of a call, with their
  clock times, in `payload`; the bubble opens them beside ours), call or system, with
  structured content in `payload`; `Post.kind` is post, event, poll,
  life_event, recommend (one suggestion per member, via `post_suggest`) or reshare. Any
  post's payload may carry `bg` (a named background for short text), `feeling` or
  `activity`. Every post carries `authorSig`, the author's Ed25519 signature over
  `Post.signedCore()` (id, author, words, time, kind, `allowReshare`); a reshare embeds
  the original's signed core so readers see whose words they are, and a reshare whose
  original forbids it, or whose signature does not hold, is dropped on receipt.
  `post_delete` is honoured from the author or a sphere admin; the deleter's own copy
  waits in a local trash for thirty days. Archiving a post is local.
  Control traffic between devices and contacts rides small sealed envelopes: `chat_edit`,
  `chat_delete`, `chat_pin`, `chat_settings`, `read`, `poll_vote`, `location_update`,
  `profile`, `devices`, `contacts`; sphere-side equivalents are `sphere_msg_*` items and the
  feed carries `post_edit`, `post_pin`, `post_settings` (comments off), `post_delete`,
  `post_suggest`, `event_rsvp`, `post_vote`, `coauthor_accept`, `report`, `comment`,
  `reaction`, `event_update` (details by the author or a named co-host; the co-host list by
  the author only), `event_photo` (any member, deduplicated by id), and on comments
  `comment_edit` (earlier text kept), `comment_delete`, `comment_hide`, `comment_pin`,
  `comment_react`. Who may do what is decided by who signed: edits by the comment's
  author, hide and pin by the post's author or a sphere admin, delete by either, a
  closed post takes no comment but its author's. Which posts notify us (follow, mute)
  is local to the device. Every one is attributed to the signed sender and, where it matters, checked
  against sphere roles on receipt. Add a new kind by extending the model, the sender, the
  switch in the receiver, and `describeMessage` for notifications.
- **Profiles.** `UserProfile` carries name, bio, picture, birthday, a structured
  `ProfileAbout` (pronouns, nickname, pronunciation, work, education, city, hometown,
  relationship and partner, family, languages, websites, hobbies, quotes, life events),
  cover and featured photos, a temporary-picture timer, a legacy contact, and an
  audience per field (`FieldAudience`: all contacts, named spheres, or only me). The
  `profile` envelope is built per contact by `ProfileSharing.payloadFor`, which cuts the
  profile to what that contact's shared spheres allow; the receiver treats the message
  as the sender's whole view and drops any field it no longer carries, while a malformed
  field is ignored. `ProfileSync` (`services/profile_sync.dart`) decides who is sent it:
  every contact on an edit, a contact when they are added, and at every start anyone
  whose last copy (remembered as a digest of their cut, sealed key
  `spheres_profile_sent_v1`) differs from what they would get now, which is how someone
  who starts sharing a sphere with us gets the wider cut. A send the relay did not take
  is owed, and goes the moment that contact's channel comes up (a start without network,
  a reconnect) rather than at the next start only; restricting or releasing a contact
  resends their cut at once; a removed contact is forgotten. Only the legacy contact is told they are one. "View as" on the
  profile screen renders exactly that cut. Photos travel as encrypted blobs. A *note* is
  a line of up to 80 characters with a 24-hour `noteUntil`; it travels only while it
  lasts and the receiver drops it when a profile arrives without one. Pictures are
  resolved by the reader from the identity key (`avatarRefFor` in `widgets/avatar.dart`:
  our own profile for our key, the contact's fetched picture for theirs), so a post,
  comment, member row or chat bubble shows the picture the person has now, never one
  that travelled with the content.
- **Messaging comforts.** Scheduled messages wait in `ChatService` (sealed key
  `spheres_scheduled_messages_v1`) and go on the 30-second sweep while this device runs;
  scheduled posts are drafts with `scheduledFor` and go on the feed's one-minute sweep.
  So that a phone asleep at the minute still sends, one platform alarm follows the
  schedule (`services/send_alarms.dart`: the earliest pending time across chat and
  feed, re-set on every change and at every start, since alarms do not survive a
  reboot). On Android it is an exact alarm (`Alarms` in `MainActivity.kt`,
  `SCHEDULE_EXACT_ALARM`); when it fires with the app alive Dart runs its sweeps, and
  with the app closed `AlarmReceiver` starts a headless engine with `--scheduled-bg`,
  which brings the hub up, sends what is due, re-sets the alarm and exits
  (`BackgroundSync.runScheduled`). Android 12+ lets the person refuse exact alarms;
  then the alarm set is inexact, the platform answers so, and the composer, the chat and
  the drafts page say the send may be late and link to the setting. Where there is no
  platform code nothing is set and nothing is promised. "Send later" is in the chat's
  attach sheet as well as behind a long press on send.
  Vanish mode is `setVanish`: a five-minute disappearing preset that remembers and
  restores the previous setting. An ignored chat (`LibraryService.isChatIgnored`) raises
  no notification and sends no typing signal or read receipt; chat theme, nickname and
  chat emoji are local (`spheres_chat_looks_v1`). "Send pictures at full size" skips the
  1600 px downscale but still re-encodes. Chat bubbles: `NotificationService.bubble` tries
  `BubbleBridge.show` for a direct message and falls back to the plain notification;
  `MainActivity.kt` posts a MessagingStyle notification with bubble metadata and
  `BubbleActivity` attaches to the cached engine (`FlutterEngineCache`, id `main`) so no
  second copy of the services starts, then asks the app to show the chat over the
  `spheres/bubbles` channel.
- **Self sphere** (`SphereService.ensureSelf`, run at every start from `wireIdentity`):
  every identity has one built-in sphere with one member, itself, named "Self". It is
  derived, not minted: its id is a hash of the identity key (`selfSphereIdFor`) and its
  first key is HKDF of the identity secret, so every device of the same identity arrives
  at the same sphere with the same key without being told, and nothing is broadcast. It
  cannot be renamed, left or opened to anyone (`StateError`); the list shows it as "Just
  you, built in" and the sphere screen hides Leave and the lone-admin warning for it.
- **A post's spheres can change after it is sent** (`FeedService.setPostSpheres`, author
  only, at least one sphere, not for a flash; "Spheres it is in…" in the post menu). A
  sphere added is sent the post as if new there (comments and reactions so far stay where
  they were made); a sphere removed is sent `post_delete` with `sphere_id`, which a reader
  honours by taking that sphere off the post and dropping it only when none is left. Both
  sides remember the (post, sphere) pairs taken out (`_unshared`, sealed key
  `spheres_unshared_v1`) so a sync round offering that copy back does not put it back. A
  client from before this reads the scoped delete as a plain one and drops the whole post,
  which errs towards less. The profile has "Your posts" and "Your activity" (posts,
  comments and reactions read off the device, `own_activity_screen.dart`).
- **Stories** are posts with `isStory` and a day's expiry. A person sees them as
  *flashes*: "Flash" everywhere the UI speaks, `story` everywhere the code does. The strip
  on Home starts folded as one thin row of rings (`_FlashStrip`) and a tap unfolds it,
  since open it took a quarter of the screen. A story may carry a sticker
  (`poll`, `question`, `countdown`, `quiz`, `slider`, `feeling`, `link`) in its payload;
  answers to the first four travel as private replies to the author, a link opens only
  when it is `http(s)` and nothing is fetched to preview it. The source sheet offers the
  rear or front camera, a three-second *loop clip* (`payload['loop']`; it plays forward
  round and round, and is not called a boomerang because it cannot play backwards), and
  a collage of two to four pictures composed on the device (`MediaService.composeCollage`,
  origin score the weakest input's, marked edited). Hiding a story from named members is
  an exclusion at send time (`createStory(hideFrom:)`): they are never sent it, and
  nobody is told. Our own stories are kept in a local archive (`storyArchive`, sealed key
  `spheres_story_archive_v1`) past their day; from there or from the viewer a picture goes
  into a *highlight*, a `UserProfile.highlights` entry with its own `ProfileField`
  audience, whose pictures travel as blobs in the `profile` envelope like featured photos.
- **Events** are posts of kind `event`; `EventTime` (pure) decides the next occurrence
  of a repeating one, whether it is over, and writes the `.ics`. Reminders are local:
  the choice lives in `LibraryService`, the alarms in the device's notification
  scheduler (`NotificationSink.schedule`, UTC instants, inexact), re-set at every start
  by `EventReminders.resync`. "Add to calendar" and `.ics` export go through the
  `spheres/calendar` platform channel in `MainActivity.kt` (Android only; elsewhere the
  bridge throws and the UI shows the message).
- **Sphere info** (`models/sphere_info.dart`, `services/sphere_info_service.dart`): rules,
  up to three join questions, post topics, a welcome line, guides (ordered post ids),
  badges, suspensions, and two automation settings (mute after N reports, invite links
  that expire). An admin publishes the whole thing as one `sphere_info` feed item with a
  version; a member keeps the newest from a signer who is an admin as of the membership it
  holds, and nothing else. Every rule is enforced locally from the copy held: a suspended
  member's post, comment or chat message is dropped on receipt and their own device
  refuses to send; `reportsReached` mutes on the admin's device; `inviteLink(maxAge:)`
  retires an old token. Keyword alerts (`LibraryService.adminKeywords`) never leave the
  device. Rules are shown until acknowledged (`spheres_rules_seen_v1`). The item is sealed
  under the epoch of its edit, and sync never offers content from before a member's time,
  so the admin who approves a join republishes it unchanged for the newcomer
  (`republish`), and a device that just accepted an invitation syncs that sphere at once
  (`SphereService.onJoined`) to pick up the welcome post made at approval. The feed opens
  a channel to every member of every sphere we are in, not only to contacts
  (`FeedService.connectSphereMembers`, keyed by the exchange key the membership list
  records); without it a member nobody here had added could not be sent anything. A
  member who is not a contact is named by what they sign their posts with.
- **Avatars and translation.** `AvatarSpec` + `AvatarPainter` draw a cartoon avatar on the
  device (`/profile/avatar`); the PNG becomes the profile picture through the usual
  `updateAvatar` path with provenance "edited with Spheres", and six expression variants
  can be added as local stickers. Translation is opt-in (`TranslationService`, off by
  default): `MlKitTranslator` wraps Google ML Kit's on-device translation and language
  identification; each language model is downloaded from Google only when the person taps
  download in Settings, Translation, and the text translated never leaves the phone.
  Translations live in memory by id (`post:`, `comment:`, `msg:`) and show under the
  original (`TranslationLine`). Tests use a fake `Translator`.
- **Wellbeing** (`services/wellbeing_service.dart`, local, sealed key `spheres_wellbeing_v1`):
  seconds on screen per day; after twenty minutes in a row `breakActive` dims the whole app
  (`BreakOverlay` in `app.dart`) for twenty seconds with a countdown, and five minutes away
  counts as a break; a daily limit raises one reminder; quiet hours silence everything but
  calls (`NotificationService.inQuietHours`); pause rests the relay (`RelayHub.pause` /
  `resume`, nothing reconnects meanwhile) and `PauseGate` covers the app, with every key and
  store untouched. Tag review (`LibraryService.tagReview`) holds a post that tags us
  (`payload['tags']`) off our profile until approved; a restricted contact's comment on our
  post is hidden on arrival (`FeedService.restrictedKeys`); `unseenCount` feeds the Home
  dot; text scale, high contrast and reduced motion live in `ThemeService` and are applied
  in the `MaterialApp` builder. Language: English only, and Settings says so.
- **Desires served, not exploited** (plan §12.6, decided 25 October 2026): the rule the next
  feature is measured against. Forbidden mechanics: variable-time rewards, numbers shown
  to everyone, anything timed to pull, loops with no end, pressure from what others see,
  anything derived from behaviour unsaid. Built so far: `AppreciationService` holds
  reactions to our posts and delivers them once a day at the person's hour as one line
  per post with every name (`spheres_appreciation_pending_v1` sealed; the hour and the
  mode in plain prefs; a reaction taken back before the hour is never mentioned; "as it
  happens" remains a choice and delivers what was held when chosen), and the feed ends
  with "You're caught up" and "Done for now" (`_CaughtUp`). The reaction count row shown
  to everyone is the standing breach, to become private.
- **The writing guide** (`models/writing_guide.dart`, pure; `widgets/writing_guide_sheet.dart`;
  "Write for an occasion" in the chat's attach sheet): the second principle of §12.6, the
  app carries words and never supplies them. For each `Occasion` (declared by the writer)
  the guide holds questions only the writer can answer, in the order a message goes,
  shown faintly and skippable, never in the draft; `notice` gives one gentle line when a
  draft over a length could be said to anyone (no name as a whole word, no memory word),
  never blocking; `canSend` needs words and nothing else. There are no templates and no
  one-tap send: the words go into the chat box, not out. "Say it instead" hands over to
  the voice note. Tests pin that no question is a sentence to send.
- **Advertisements** (`models/advert.dart`, `services/ad_service.dart`,
  `services/ad_catalogue.dart`; sealed key `spheres_adverts_v1`): the television rule.
  `AdService` counts seconds on screen, any screen, and after twenty minutes puts one
  advert in the slot on Home (`_AdvertSlot` above the posts, `AdvertCard`), where it stays
  until closed; the clock does not run while one is up. Nothing about the person is read
  or sent to choose it: the phone fetches the *whole* catalogue (`AdCatalogue`; the
  operator's source is `NoAdverts` today, `JsonAdCatalogue(url)` is the one that serves a
  version-1 JSON document with no identifier in the request) and picks on the device the
  least recently shown advert in a category kept on, ties by id. Categories are a fixed
  list of twenty-four in the app (`AdCategory.all`); a catalogue entry outside it, or
  short of a whole advert, or with a link that is not http(s), is dropped. The choice is
  `AdChoice` (pure): the free plan keeps at least ten categories on and refuses the
  eleventh off with a `StateError` (the switch is disabled first); the paid plan may reach
  zero; a move back to free turns categories on in list order up to the floor. There is no
  way to buy a plan yet and Settings, Advertisements says so, as it says that no adverts
  are shown at present; the choices are kept for the day they are. Which advert was shown,
  when, and that one was shown at all stay on the phone. To try the path before the
  operator carries anything, the same screen takes a catalogue address for this phone
  alone (`AdService.setTestUrl`, plain preference `adverts_catalogue_url`, http(s) only;
  it replaces the operator's source until cleared) and a "fill the slot now" action
  (`fillSlotNow`); `landing/ads/test-catalogue.json` is served at
  `https://spheres.dev/ads/test-catalogue.json` with three good adverts and two the app
  must drop. The operator's real catalogue, when there is one, is the same shape at a
  path beside it, named in `AppServices`. Billing can only ever be airtime (a slot in a
  category for a period), since the phone reports no impression; an advertiser portal is
  for later and needs no change in the app.
- **Look.** The layout is the one people know from the big social apps, on purpose, so
  that it feels like home; the marks that would make it read as a copy of one are not
  used. No thumb and no "Like": `ReactionKinds` offers Respect (the tap default), Cool,
  Wow!, Adorable, LOL, Sad, Angry and Not for me, and still accepts and names the five
  kinds from before (`legacy`) so an older reaction or client keeps its meaning. The
  action row is a reaction glyph, Comment and Pass on; the composer says "Say something
  to your spheres"; the neutrals in `theme/app_theme.dart` carry a trace of the rose
  rather than a palette lifted from elsewhere; headings use Outfit, bundled under
  `assets/fonts` (SIL OFL) with the body in the system font. The runtime font package
  that used to set Inter asked Google's servers for it at every start and is gone. The
  bottom bar is Home, Spheres, Chat, Contacts, Profile, with the product's own object in
  the middle. The sphere a post reached us through is named on its card.
- **Invite links** are `spheres://join?s=&t=&via=&n=&q=`; `q` carries the sphere's join
  questions, the request carries the answers, and approval makes the requester a contact
  and a member in one step, then posts the welcome line if the sphere has one.
- **Not built, by decision:** an SFU for large group calls (mesh only), any pixel-level
  classifier (nudity or AI-image detection; the origin score reads metadata only),
  communities as spheres of spheres, pending-post approval queues, story drawing. Every
  milestone of `docs/facebook_feature_list.md` (P1 to P10) has landed as of 12 October
  2026, and P5 to P10 had their first hardware pass that evening (see the second rule).
- **Still open:** APNs, reproducible-build proof, external audit. See the plan's §13.
  The project's coturn and ntfy both run on the Scaleway instance under their own names
  with TLS; a phone whose ntfy app points at `https://ntfy.spheres.dev` is woken through
  it (the Samsung is, the Motorola still uses the public ntfy.sh until its ntfy app is
  pointed over). Every M1 item has now run on hardware: background wakes through ntfy,
  restoring an encrypted backup from Settings and a call forced through TURN all passed
  on 11 October 2026.
- Directory names: the app is `safesocial_app/`, the Dart package `spheres_app`, the
  product Spheres.

### House rule

**A stub must never report success.** Code that cannot do its job throws or returns an
explicit error. Silent placeholders are what turned incomplete work in this repo into
invisible incomplete work. If a feature is not finished, the UI says so.

### Second rule

**The message path has run on real hardware once** (11 October 2026: a Samsung S23+ on
Android 16, a Motorola Edge 20 Fusion on Android 13 over Wi-Fi adb, and a Samsung tablet
as a third party; two devices linked to one identity, a message from the third landing on
both and a reply from either reaching the third and the sibling). Direct
chat, media, offline delivery, spheres, posts and sphere chat worked; the first call
crashed the receiver and a half-dead socket lost sphere messages, both fixed the same
day. A ntfy wake brought a stopped app back with a notification, and an encrypted
backup restored from Settings (which had never asked for the passphrase; fixed). The
evening's two-phone pass on one identity found that the feed opened its channel to our
own devices before it had our key, so after any restart a post never reached the linked
phone (fixed, with a log line where the quiet return was), and that a sibling that missed
one membership op refused every later one for good (fixed: an op our own identity signed
on another device is adopted as it stands). The P4 pass found the tablet two membership
changes behind and deaf to the whole sphere ("No key for epoch 4" on every post, with
nothing that would ever bring the key); a member now asks the admins for the key when
content arrives for an epoch it lacks, and an admin answers that member with a signed
`sync` snapshot carrying every key from the member's epoch to the admin's
(`SphereService.requestKey` / `keyAnswerFor`, throttled, never logged as a change). A key
from before we joined is never asked for, and a sync digest says the oldest epoch we can
read so peers do not keep offering what was sealed before. The same pass found that a
story hidden from a member reached them through sphere sync anyway; an archived envelope
now remembers who it is not for (`SphereSyncService.remember(notFor:)`). The P5 to P10
pass of 12 October 2026 ran the three devices as three people (the Motorola reset to a
fresh identity, approved into the sphere through an invite link with two questions) and
found that a sphere member nobody had added as a contact was unreachable, because the
feed opened channels to contacts only (fixed: channels to every member); that the rules
and the welcome post never reached a newcomer, sealed before their epoch and dropped
before they had accepted (fixed: republish at approval, sync at join); that the invite
dialog drew nothing at all, a QR widget inside a dialog failing layout (fixed: `QrBox`);
that an owed profile send waited for the next start and a restricted contact kept the
fuller copy (fixed: resend on reconnect and on the change); and that a stale "waiting
for them to approve" label outlived the fact (fixed: a sealed message clears it). Rules,
topics, badges, suspension, keyword alerts through a ntfy wake, events with a co-host
and an RSVP back, vanish mode, pokes, notes, tag review and a drawn avatar all crossed
between the three. When a change touches the message path, say so in the commit and
prefer changes that a test can cover. Emulator pairs cannot
scan QR codes; debug builds print the invite link instead (see `identity_service.dart`).

## Build & run

### Flutter app (`safesocial_app/`)
```bash
flutter pub get
flutter analyze --no-fatal-infos   # errors and warnings must stay at zero
flutter test                       # 885 tests in 83 files under test/{crypto,models,screens,services}
flutter test test/some_test.dart
flutter run --flavor foss          # or --flavor play; every build names a flavour now
flutter build apk --debug --flavor foss
flutter build apk --flavor foss    # release — needs android/key.properties, refuses debug key
flutter build appbundle --flavor play   # the Google Play upload
```
The toolchain is pinned in `FLUTTER_TOOLCHAIN` (Flutter 3.41.5, Dart 3.11.3, Gradle 8.14,
AGP 8.11.1, Kotlin 2.2.20, Java 17). Bump it in a commit of its own.
`PUB_CACHE` on this machine points at `/mnt/ssd/pub-cache`; if that volume is not
mounted, `pub get` fails with a permission error rather than a missing-path error.

### Release
```bash
./build_release.sh                 # bumps app_info.dart + pubspec, builds, writes SHA256SUMS.txt
scripts/verify_build.sh            # rebuilds a release and diffs the bytes
python3 scripts/make_logo.py       # renders logo.png and every launcher icon (one shaded sphere, three wave bands)
```

### Relay (`relay/`)
```bash
npm test                           # node --test, in-process fake Durable Objects, real Ed25519
npx wrangler dev
npx wrangler deploy                # deploy together with the client; v3 clients need the hub
```

### Edge box (`infra/`)
coturn and ntfy on the Scaleway instance, as code: `setup.sh` (run on the box with
`PUBLIC_IP`, `TURN_HOST`, `NTFY_HOST`) writes the configs from the templates there and
`check.sh` proves STUN, TURN-over-TLS and ntfy from outside. The TURN secret lives in
`/etc/turnserver.conf` on the box and as the Worker secret `TURN_SECRET`; it is not in
the repo. Change a config there, not by hand on the box.

### CI (`.github/workflows/ci.yml`)
Analyze, test, debug APK; a second job builds the same commit twice and fails if the bytes
differ; a third runs the relay tests.

## Architecture (as built)

```
Flutter UI (Provider/ChangeNotifier + GoRouter)
    ↓
AppServices (lib/app_services.dart) builds and loads every service, in order;
app_wiring.dart connects the identity to all of them (startup, onboarding, link)
    ↓
Dart services (lib/services/) — one ChangeNotifier per concern
    Identity (devices) · Contact (device lists, bundles) · Chat · SphereChat · Feed · Album
    Sphere · SphereSync · Sync (device link) · Call · Media · Blob · Outbox (per device)
    Search · Backup · Library · Notification · Wake · SecureStore
    ↓
Crypto (lib/crypto/) — device certs, per-device-pair sessions, envelopes v3, keyring,
    mailbox derivation, blobs, vault, Shamir
    ↓ one WebSocket to /hub, signed HTTP for everything else
relay/worker.js — Cloudflare Worker + Durable Objects, EU jurisdiction
    /hub/<id>        one socket per client; sub/pub/msg frames
    /mbx/<addr>      mailbox: sync/ack, subscribe/publish, post (federation), wake
    /inbox /blob /prekey /turn
```

- Six services still hold their own `RelayService` facade; that is fine now, they share one
  socket through `RelayHub`.
- The relay cannot identify participants: an address is derived from a secret only the
  participants share. It sees timing, size buckets, and which addresses one client holds.

## Storage model

| Store | Contents |
|---|---|
| `flutter_secure_storage` | `spheres_identity_secret`, the `SecureStore` wrapping key |
| `SharedPreferences` via `SecureStore` (sealed) | sessions, keyring, spheres, sphere chats, messages, contacts, posts, outboxes, albums, archive, invites, audit log, votes |
| `SharedPreferences` plaintext | `theme_mode`, relay host, call config, the hub id — nothing secret |
| App documents dir | `backups/*.spheres`, decoded media, voice notes |

New sensitive keys must be added to `SecureStore`'s sensitive-key list or they are written
in plaintext.

## Conventions

- **State:** Provider with `ChangeNotifier`; services injected at the root.
- **Navigation:** GoRouter with named routes.
- **Wire format:** every payload is an `Envelope` (signed, sealed) whose plaintext is JSON
  with a `type` field. New message kinds get a parser test and an entry in
  `test/crypto/parser_fuzz_test.dart`.
- **Tests:** a bug fix on the message path comes with a test that fails before the fix.
  Several past fixes were found by two-emulator live tests; record those in the commit.
- **Commit messages** describe the user-visible change in plain words (see `git log`).
- **Docs:** `README.md` and this file describe the code as it is. If you change what is
  built, change them in the same commit.

## Current status

Pre-alpha. Phases 0–5 of the plan are implemented; §13's M2–M8 landed in October 2026
(hub transport, media, backups, push, TURN issuance, federation, multi-device). The first
two-phone session (M1) ran on 11 October 2026 and its findings are being fixed; the rest
of M1 is listed under "Still open" above. Release numbers
and the toolchain pin are in `app_info.dart` and `FLUTTER_TOOLCHAIN`.
