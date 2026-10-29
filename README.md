# Spheres

**Your data. Your network. Your rules.**

Spheres is an in-development social network built so that no content has a public
audience: everything lives inside a *sphere*, a named group with an explicit
membership list and its own encryption key. Your identity is a cryptographic keypair,
not an email address or phone number.

> ## ⚠️ Pre-alpha — unaudited, run on two real phones once
>
> Everything that crosses the network is end-to-end encrypted (X25519 key agreement,
> HKDF, XChaCha20-Poly1305, Ed25519 signatures), local storage is encrypted at rest,
> and the relay derives its addresses from shared secrets so it cannot tell who talks
> to whom. What is still true:
>
> - **Nothing here has been independently audited.**
> - **No two physical devices have exchanged a message.** Everything has been
>   exercised through 534 unit tests, a relay test suite and two emulators. Unknown
>   unknowns dominate every other risk; the first two-phone test is the next milestone.
> - **The relay sees timing and bucketed message sizes**, and Cloudflare sees IP
>   addresses. There is no peer-to-peer path. Each person uses the relay they choose
>   and contacts send there, so no single operator is structural, but today there is
>   one default.
> - **Calls use the operator's TURN server when a direct path fails.** The relay issues
>   short-lived credentials for it; a relay without one falls back to public STUN and
>   only connects over a direct path, and Settings says which applies. The project's
>   coturn runs on a Scaleway instance in Amsterdam and has carried one forced call
>   between a phone and a tablet. The old public TURN default is gone.
> - **Push is content-free, and Google is a choice, not a dependency.** Android wakes
>   through UnifiedPush; iOS through APNs. The `foss` build carries no Google code and
>   needs a distributor such as ntfy, whose open connection costs a persistent
>   notification. The `play` build embeds the UnifiedPush FCM distributor, which
>   registers with Google Play services the way a browser does (the relay's VAPID key as
>   the sender; no Firebase project, no Google SDK), so it wakes with nothing else
>   installed and Google learns only that this endpoint was poked, and when. The relay
>   signs every knock (RFC 8292) and, where the device gave keys, sends the fixed word
>   "wake" encrypted to them (RFC 8291), because Google drops a push with no bytes. Proven
>   on a phone with the app process gone: a knock through the project's own ntfy server in
>   Amsterdam brought it back and a message produced a notification within five seconds.
>   The APNs key is still to come; without it the iOS app says so.
> - **Multi-device has run on hardware once.** Each device has its own key, certified by
>   the identity; contacts seal once per device. See `docs/rebuild_plan.md` §12.4 for what
>   revoking a device can and cannot do.
>
> The plan for closing these gaps, and the decisions behind it, is in
> [`docs/rebuild_plan.md`](docs/rebuild_plan.md).

## The model

**Everything is a sphere.** A direct message is a sphere with two members; a group chat,
a shared album, and a "close friends" audience are the same primitive with different
presentation. There is no "everyone" and no public profile. Content that is not addressed
to a sphere does not exist, and the code path that would produce it does not exist either.

Non-goals, deliberately: global discovery, trending, public profiles, follower counts,
server-side moderation (membership is the moderation), and resistance to a state-level
adversary who already controls your device. The target is no bulk surveillance and no
platform-side data mining.

## Current state (v0.8.0)

| Area | Status |
|---|---|
| Identity (Ed25519 signing + X25519 exchange keys, platform keystore) | Working |
| Contacts: QR exchange, approval before adding, blocking | Working |
| Spheres: create, invite, accept, leave, remove with key rotation | Working |
| Sphere governance: owner/admin roles, transfer, removal by vote, audit log, rules, membership questions, topics, welcome posts, guides, badges, suspensions, keyword alerts, mute after N reports, expiring invite links | Working; rules, topics, badges, suspension and a keyword alert ran between three phones on 12 October 2026 |
| Direct chat: ratcheted sessions per device pair, durable outbox, receipts, session repair | Working |
| Sphere chat: group conversation owned by a sphere | Working |
| Feed: posts to one or several spheres, comments, replies, reactions, saves | Working |
| Stories: sphere-scoped expiry, author-only view receipts, private replies, selfie and loop clips, collages, quiz, slider, feeling and link stickers, hide from named members, a local archive, highlights on the profile | Working; stickers and hide-from untested on hardware |
| Albums: sealed per sphere, synced like everything else | Working |
| Media: per-blob keys, 48 KB encrypted chunks, inline thumbnails, EXIF/GPS stripped | Working; video transcoded on-device to 720p (60 s feed, 3 min chat, 64 MB), poster frames, in-app playback, save to gallery |
| Media origin score: a 0–10 trust badge on every picture, from the file's own data on the sender's device (camera EXIF, editing tags, Content Credentials and generator marks, name, size); in-app camera capture scores 10; blur-until-tapped per chat or sphere | Working; a reading of the file's claims with a disclaimer, not a detector; untested on hardware |
| Protected photos and videos: shown only while held with two fingers, ten seconds at a time, blurred otherwise; decrypted in memory and never cached; screenshots blocked on Android; no save, share, forward or reshare; an optional watermark with the viewer's name; a CRT-style scan over the blurred picture against a second camera | Working on Android; iOS cannot block screenshots and the viewer says so; the sender is told the other phone enforces it |
| Pictures that wait for the people in them: a tagged photo's key is sealed to the tagged people only, one share each; everyone else sees a blurred frame and "Waiting for Al" until each has said yes, and holds nothing that opens it before then | Working; ran between three phones on 12 October 2026 (the tablet waited for Moto, then opened the picture on Moto's yes) |
| Voice/video calls over WebRTC, signalling encrypted; the camera or screen can be turned on in a voice call and off in a video call, by either side, mid-call | 1:1 working on hardware, direct and through the project's TURN; group (mesh) on emulators only; the mid-call switch is new and untested on hardware |
| Local search over messages, posts, comments, spheres, contacts | Working |
| Edit own posts, pin posts in a sphere (admins), archive chats and spheres, mute a member within a sphere, per-sphere media gallery | Working |
| Key verification: safety number and QR comparison per contact, with a banner when keys change | Working |
| Messaging extras: a writing guide for an occasion that asks what only you can answer and never writes a word for you, disappearing messages and a vanish-mode preset, view-once media, edit and unsend, forward, star, pin, mentions, polls, read receipts, video notes, live location, contact cards, files of any type, scheduled messages that go at their minute with the app closed (an exact alarm wakes the phone), chat themes, nicknames and a chat emoji, ignore, full-size photos, chat bubbles on Android, a profile note for a day, chat lock, export, filters | Working; vanish mode, pokes and notes ran between phones on 12 October 2026; files and scheduling on tests only |
| Feed extras: events with RSVP, poll posts, co-authored posts, alt text, drafts and scheduled posts, flashes (stories) in a strip that starts folded, with captions and stickers, hidden-words filter, report to the sphere | Working; an event with a co-host and an RSVP ran between phones on 12 October 2026 |
| Comments: reply threads, eight reactions on posts and comments (Respect, Cool, Wow!, Adorable, LOL, Sad, Angry, Not for me; no thumb, no "Like"; the five older kinds are still accepted from earlier clients), edit with history, delete, hide and pin by the post's author or an admin, comments off per post, follow or mute a post, newest-first | Working; comment, reaction, reply, hide and edit checked between a phone and a tablet |
| Spheres: invite links with admin approval, private member notes, birthdays and avatars shared with contacts; a built-in Self sphere with one member, derived from the identity so every device has the same one | Working; untested on hardware |
| Composer: the spheres a post is in can be changed after it is sent (a sphere added gets it, one removed is told to drop it, scoped so a reader in another of its spheres keeps it), coloured backgrounds for short text, feeling or activity, life events, asking for recommendations, resharing into another sphere with the author's signed words, pin to profile, delete with a thirty-day trash, archive, bulk manage, picture editing (rotate, flip, crop, text, stickers, drawing), a look (colour and light as numbers applied by every viewer, the original one hold away, presets and sliders, changed after posting with nothing re-sent, nothing that changes a face), 360° photos panned in the viewer, video trim and cover frame | Working; signature, reshare, delete and trim rules covered by tests, untested on hardware |
| Events: co-hosts who may edit, repeating events with the next occurrence shown, going/interested/maybe/can't go, photos added by anyone in the sphere, reminders shown by the phone, add to the device calendar, .ics export, a map link, an upcoming-events list | Working; the rules are covered by tests; calendar and export are Android only and say so elsewhere; untested on hardware |
| Contacts and feed: mute, unfollow, snooze for 30 days, take a break (quiet and restricted until ended), restrict (they get only your name and picture), favourites and a favourites-only feed, birthday and anniversary cards, data saver | Working; local only, nothing is told to the other person; covered by tests, untested on hardware |
| Profile: cover and featured photos, pronouns, nickname, pronunciation, work, education, places, relationship and family, languages, websites, hobbies, quotes, life events, a temporary picture that reverts, a legacy contact, an audience per field and a "view as" that shows exactly what each contact gets | Working; the per-contact cut is covered by tests, untested on hardware |
| Calls: history, missed-call notifications, screen sharing, join a sphere call from its chat; notes from your own words in a call, made on the phone by the AutoEar engine behind on-device speech recognition: a button in the call turns them on for both phones, each noting its own voice, and at the end each is asked whether to send its notes to the other; every note carries the time it was said, and notes received from the other side are laid beside yours in the order things were said | Working; screen share needs platform support, large calls still mesh; call notes need Android 13, are rule-based and often wrong, and are untested on hardware |
| Local sticker packs, app lock and locked chats with biometrics, security notices on key changes, inbox rate limiting | Working |
| Drawn avatars with matching stickers; opt-in on-device translation of posts, comments and messages through ML Kit models downloaded on request | Working; translation untested on hardware |
| Wellbeing and accessibility: appreciation delivered once a day at your hour as one line per post with every name rather than one notification per reaction, a feed that ends with "You're caught up" and a way out, a twenty-second dimmed break every twenty minutes of use, a time dashboard, daily reminder, quiet hours, pause that keeps the keys, privacy checkup, tag review, restricted contacts' comments hidden on arrival, crisis helplines, text size, high contrast, reduced motion, search history, notification dots, year in review, poke | Working; untested on hardware |
| Advertisements, the television way: one slot on Home after every twenty minutes of watching, picked on the phone from categories the person keeps on (free plan: at least ten of twenty-four; paid: any number, none yet sold), from a catalogue fetched whole so the host learns nothing about the choice; nothing shown or chosen leaves the phone | Framework in place with tests; no adverts are carried today and Settings says so; a per-phone catalogue address and a test catalogue at spheres.dev let the path be tried |
| Terms of use agreed at onboarding; "Report to Spheres" on posts, messages, contacts and in Settings, sealed on the phone to the operator's key so the relay stores what it cannot read; an operator tool to open reports and ban an identity from being found or added | Working; the live relay path proven end to end, the phone side untested on hardware |
| Encrypted backup, identity export/import (Argon2id + XChaCha20) | Working; covers every store except sessions and outboxes |
| Social recovery (Shamir, verified against the public key) | Working |
| Multiple devices (per-device keys, signed device list, link/revoke) | Implemented, with tests; not yet exercised on hardware |
| Local storage encrypted at rest (`SecureStore`) | Working; key names and entry counts remain visible |
| Notifications and push wake (UnifiedPush / APNs, content-free; `play` build wakes through Google Play services without a Google SDK) | Working on Android through the project's ntfy server and, in the `play` build, through Google Play services (three devices, app process gone, woken and notified seven seconds after the knock); an app off screen lets its socket go so the relay knocks rather than feeds a socket Android has cut; the APNs key is still to come |
| Federation: each contact reached on the relay they chose | Implemented; relay host travels in the signed bundle |
| Peer-to-peer / Veilid / DHT | Not implemented, not planned for now |

## Architecture (as built)

```
+---------------------------------------------------------------+
|                         Flutter UI                            |
|      screens, widgets, Material 3 theme — Provider + GoRouter |
+---------------------------------------------------------------+
|                       Dart services                           |
|  Identity · Contact · Chat · SphereChat · Feed · Album        |
|  Sphere · SphereSync · Sync (device link) · Call · Media      |
|  Blob · Outbox · Search · Backup · Library · SecureStore      |
+---------------------------------------------------------------+
|                     Crypto (lib/crypto/)                      |
|  pairwise ratchet sessions · sphere keyring · envelopes       |
|  mailbox derivation · chunked blobs · vault · Shamir          |
+---------------------------------------------------------------+
|              relay/worker.js — Cloudflare Worker (EU)         |
|  /hub   one socket per client, mailboxes subscribed by sig    |
|  /mbx   secret-derived pairwise mailboxes, 30-day queue, wake |
|  /inbox first contact   /blob media chunks   /prekey bundles  |
|  /turn  short-lived credentials for the operator's coturn     |
+---------------------------------------------------------------+
```

The app is 100% Dart. The dormant Rust crate and its bridge were removed in October 2026;
git history has them.

There is no database. Everything is local, in `SharedPreferences` behind `SecureStore`
(sealed with XChaCha20-Poly1305 under a key in the platform keystore), with the identity
secret itself in `flutter_secure_storage`. Decoded media and backups live in the app
documents directory.

## Prerequisites

- **Flutter**, pinned for reproducible builds in [`FLUTTER_TOOLCHAIN`](FLUTTER_TOOLCHAIN)
  (currently 3.41.5 / Dart 3.11.3).
- **Platform tools**: Android SDK or Xcode for mobile; the desktop targets exist but are
  untested.
- **Node 22 and wrangler**, to test or deploy the relay.

## Quick start

```bash
cd safesocial_app
flutter pub get
flutter analyze --no-fatal-infos   # must be clean
flutter test                       # 798 tests in 75 files
flutter run
```

Release builds require `safesocial_app/android/key.properties`. Without it the release
build fails by design: it must never fall back to the public Android debug key.
`build_release.sh` bumps the version, builds, and writes `SHA256SUMS.txt`;
`scripts/verify_build.sh` lets anyone rebuild a release and diff the bytes.

## Project structure

```
safesocial/
  safesocial_app/        Flutter application (Dart package name: spheres_app)
    lib/
      main.dart          Entry point, Provider setup
      app_wiring.dart    Connects an identity to every service (startup and post-onboarding)
      app.dart           GoRouter configuration, navigation shell
      app_info.dart      Version strings shown in the UI
      crypto/            Sessions, sphere keyring, envelopes, blobs, vault, Shamir
      services/          One ChangeNotifier per concern; SecureStore for storage
      screens/           UI by area (chat, feed, spheres, media, settings, ...)
      models/            Equatable data models with JSON serialization
      widgets/           Reusable components
    test/                crypto/, models/, services/ — plus a seeded parser fuzzer
  relay/                 Cloudflare Worker + Durable Objects, with tests; see relay/README.md
  infra/                 The EU edge box as code: coturn, ntfy, Caddy; setup and check scripts
  landing/               Project website
  scripts/               verify_build.sh
  docs/
    rebuild_plan.md             The plan, its decisions, and what remains — start here
    threat_model.md             Current; adversary by adversary against what is built
    privacy_protocol.md         The cryptographic design, now implemented
    reproducible_builds.md      How to verify a release
    architecture_weaknesses.md  The 2026-07 findings that motivated the rebuild (historical)
    feature_landscape.md        What mainstream platforms have and what Spheres cannot build
    feature_review.md           What to build from that landscape
    facebook_feature_list.md    The Facebook app item by item against Spheres, and the parity plan
    architecture.md, protocol.md, analysis_review.md   Original Veilid-era design (historical)
```

## Part of SafeSelf

Spheres is the second phase of the **SafeSelf** umbrella project:

1. **SeeSelf** (Phase 1): a personal data audit crawler that discovers what information
   about you is publicly available and models what an AI system could infer from it.
2. **Spheres** (Phase 2): this project. A social network with no public audience, as a
   practical alternative to surveillance-based platforms.

If SeeSelf shows you how exposed you are, Spheres gives you a way to take back control.

## License

TBD
