# The Facebook app, feature by feature

A fine-grained inventory of what the Facebook mobile app offers a person, as of
mid-2026, written from model knowledge (cutoff June 2026) rather than a fresh research
pass; specifics drift, structure does not. It exists to be held against Spheres item by
item. The coarser, flagged inventory is in `feature_landscape.md` §3; the prioritised
review is `feature_review.md`.

Each item carries one mark for Spheres:

- **✓** built
- **~** partly built
- **○** buildable here, not built (some by decision; see `feature_review.md`)
- **✗** cannot exist without a public audience, a central index, ads or Meta's servers

## 1. Profile

**Profile photo.** Upload from gallery ✓ · take with camera ✓ · pick from own earlier
photos ○ · crop and zoom ~ · temporary profile picture that expires ✓ · frames and
filters ○ · cartoon avatar as profile picture ○ · the change becomes a post that friends
react to and comment on ✓ (into the spheres you tick) · audience for the photo itself ✗
by design (a contact who cannot see your picture is not a contact).

**Cover photo.** Upload ✓ · reposition ○ · pick from album ○ · audience ✓.

**Identity fields.** Display name ✓ · nickname ✓ · pronouns ✓ · short bio ✓ · name
pronunciation ✓ · gender ○ (pronouns cover most of it) · birthday with its own audience ✓
· featured photos ✓ · work and education ✓ · current city and hometown ✓ · relationship
status with partner tagging ✓ · family members ✓ · websites ✓ · contact info and social
links ○ · languages ✓ · religious and political views ○ (deliberately not a field) ·
places lived ~ (city and hometown) · favourite quotes ✓ · hobbies ✓ · life events ✓.

**Profile mechanics.** Per-field audience ✓ (all contacts, named spheres, or only me;
there is no public) · profile lock ✗ · "view as" ✓ · profile link and QR code ✓ · vanity
username ✗ (a central name index) · tabs for posts, photos, videos, reels, check-ins,
friends, about ~ · professional mode ✗ · multiple personal profiles ✓ (several
identities, one per device set) · legacy contact ✓ (told, and suggested as a recovery
guardian) · memorialisation ○ · Meta Verified ✗.

**Activity log and history.** Activity log ✓ (audit log) · manage posts in bulk ○ ·
archive ✓ · trash with 30-day restore ○ · story archive ○ · download your information ✓
(backup) · transfer your information ✗.

## 2. Friends and the social graph

Send, accept, decline and cancel friend requests ✓ · who may send requests ~ (inbox rate
limiting) · people you may know ✗ · contact upload and sync ✗ · mutual friends ✗ (would
leak graphs) · friend lists: close friends, acquaintances, family, custom ~ (spheres are
the lists) · restricted list ○ · followers and public following ✗ · unfollow but stay
friends ✓ (mute) · snooze for 30 days ○ · take a break from someone ○ · unfriend ✓ ·
block ✓ · birthdays list ✓ · friend anniversaries and "friendversary" videos ○ · invite
friends by link ✓ · 5,000-friend cap, not applicable.

## 3. Composing a post

Text ✓ · coloured backgrounds and large text ○ · photo, several photos ✓ · video ✓ ·
albums and shared albums ✓ · GIF ✗ as normally built (GIPHY is a central index) ·
feeling or activity ○ · tag friends ✓ (mentions) · check in at a place ✗ (place index;
sharing a location in chat ✓) · link with preview ○ (preview fetch leaks the URL; by
decision off) · poll ✓ · ask for recommendations ○ · life event ○ · sell something ✗ ·
fundraiser ✗ · audience selector per post ✓ (which sphere) · custom audiences ~ · schedule
○ … ✓ (drafts and scheduled posts) · turn off commenting ○ · who can comment ○ · turn off
notifications for a post ○ · edit with edit history ✓ · delete ✓ · move to archive or
trash ~ · save ✓ · pin to profile ○ (pin in sphere ✓) · 360 photo and video ○ · photo
editing: crop, filters, text, stickers, doodle ○ · automatic alt text ✗ (a model) ·
custom alt text ✓ · video trim ○ · automatic captions ✗ · thumbnail choice ○ · music on
posts ✗ (licensed catalogue) · co-author ✓ · cross-post to Instagram ✗ · embed on the web
✗ · copy link ~ (invite links exist; post links do not) · share to feed, story, group,
Messenger, external app ~ (forward in chat ✓; reshare to feed ○; external ✗).

## 4. Stories

Photo, video, text story ✓ · boomerang ○ · music ✗ · layout and collage ○ · selfie mode ○
· poll sticker ✓ · question sticker ✓ · countdown ✓ · quiz and slider ○ · GIF stickers ✗ ·
mention sticker ✓ · location sticker ✗ · feeling sticker ○ · donation sticker ✗ · link
sticker ○ · drawing tools ○ (by decision) · text caption ✓ · audience: public ✗, friends
✓, custom ~ · hide story from specific people ○ · who viewed ✓ · reply in chat ✓ ·
reactions ✓ · mute someone's stories ✓ · archive ○ · highlights ○ · cross-posting from
Instagram ✗.

## 5. Reactions and comments

Reactions: seven kinds on posts ✓ (Like, Love, Care, Agree, Disagree, Sad, Wow; Spheres
keeps Agree and Disagree where Facebook has Haha and Angry) · see who reacted ✓ ·
reaction counts ✓ · comment with text ✓ · photo in a comment ○ · GIF ✗ · sticker ○ ·
emoji ✓ · mention in a comment ✓ · link in a comment ○ · threaded replies ✓ · react to a
comment ✓ · edit a comment with history ✓ · delete own comment ✓ · hide a comment ✓
(post's author or admin; the writer still sees it) · report a comment ✓ (to the sphere)
· pin a comment ✓ · turn comments off ✓ · sort comments: most relevant ✗, newest ✓, all
✓ · see translation ✗ (server-side) or ○ (on-device model) · subscribe to a post's
notifications ✓, and mute one ✓ · reaction notifications ✓ · hidden words for comments
✓ · keyword moderation for admins ○ · ban someone from a post ○ · hashtags in comments
✗.

## 6. Feed

Home feed ranked by engagement ✗ · "Feeds" tab with Favourites, Friends, Groups, Pages,
Most recent ~ (chronological only, filters by sphere ✓, favourites ○) · reels feed ✗ ·
video tab ✗ · marketplace tab ✗ · memories and "on this day" ✓ · suggested for you ✗ · ads
and sponsored ✗ · birthday cards in feed ○ · hide a post ○ · snooze a person or sphere ✓ ·
"why am I seeing this" ✗ (nothing is ranked) · feed preferences and defaults ~ · reconnect
prompts ✗ · people you may know cards ✗ · sound on and off for video ✓ · autoplay
setting ○ · data saver ○.

## 7. Messaging (Messenger inside the app)

One-to-one ✓ · groups ✓ (sphere chats) · end-to-end encryption ✓ (always, no opt-in) ·
disappearing messages ✓ · vanish mode ○ · reactions ✓ · reply quoting ✓ · forward ✓ ·
unsend ✓ · edit within a window ✓ · voice messages ✓ · video messages ✓ · photos and
video, HD toggle ~ (always re-encoded; original quality ○) · files ○ · GIFs ✗ · stickers
✓ (local packs) · avatar stickers ○ · emoji ✓ · chat themes ○ · nicknames ○ · chat emoji
○ · polls in groups ✓ · mentions ✓ · pinned messages ✓ · message requests ✓ · archive ✓ ·
mute ✓ · ignore ○ · block ✓ · read receipts and read-by ✓ · typing ✓ · active status ✗
(presence is metadata; by decision) · stories inside messaging ~ · voice and video
calls ✓ · group calls ✓ (mesh, small) · screen sharing ✓ · call links ✓ (in sphere chat) ·
effects and filters ○ · live location ✓ · payments ✗ · games ✗ · chat bubbles ○ ·
scheduled messages ○ · app lock ✓ · chat lock ✓ · secret conversations, superseded ·
search in chats ✓ · media gallery per chat ✓ · Notes on profile ○ · broadcast channels ✗
· Meta AI in chat ✗ · communities ○ (by decision) · export a chat ✓ · contact cards ✓ ·
video notes ✓ · call history and missed calls ✓.

## 8. Groups (spheres)

Create ✓ · public ✗ · private visible ✗ · private hidden ✓ (every sphere) · join by
approval ✓ · membership questions ○ · rules ○ · admins and moderators ✓ (roles) · post
approval ○ (by decision) · scheduled posts ✓ · announcements and featured posts ✓ (pin) ·
units and guides ○ · files ○ · events ✓ · polls ✓ · anonymous posts ✗ (everything is
signed; by design) · badges ○ · member reports ✓ · keyword alerts ○ · mute members ✓ ·
suspend ○ · remove and ban ✓ · vote to remove ✓ · transfer control ✓ · group chats ✓ ·
subgroups ○ · admin assist automation ○ · insights ✗ · welcome posts ○ · invite by link
✓ · group QR ✓ · post topics and tags ○ · expert badges ○ · cover image ✓ · member notes
✓ (private) · buy and sell groups ✗ · social learning ○.

## 9. Pages, events, and the other surfaces

Pages with roles, insights, call-to-action, shop, reviews, ads ✗ · professional mode ✗.

Events: create ✓ · public ✗ · private ✓ · co-hosts ○ · recurring ○ · ticket links ○ ·
invites ✓ · RSVP going, interested, can't go ~ (going and not) · discussion ✓ (comments)
· photos ○ · reminders ○ · calendar export ○ · map ✗.

Marketplace ✗ · Dating ✗ · Gaming and instant games ✗ · Fundraisers and donations ✗ ·
Jobs ✗ · Watch and video ✗ · Live and scheduled live ✗ (by decision) · Stars and tipping
✗ · fan subscriptions ✗ · Meta Pay ✗ · Avatars ○ · Memories ✓ · Saved with collections ✓
· Meta AI assistant ✗ · crisis response and safety check ✗ · blood donations ✗ ·
community help ✗ · voting and climate information centres ✗ · weather ✗ · Facebook Lite,
not applicable.

## 10. Notifications

Push ✓ (content-free wake, built on device) · in-app tab ✓ · per-kind settings ✓ · email
and SMS ✗ · birthday reminders ✓ · tagged in a post ✓ · comment on your post ✓ · reply to
your comment ✓ · reactions ○ · turn on for a post ○ · mark all read ✓ · badge counts ✓ ·
quiet mode and scheduled quiet hours ○ · notification dots ○.

## 11. Search

Global search of people, posts, photos, videos, marketplace, groups, pages, events,
places ✗ · search your own messages, posts, spheres and contacts ✓ (local) · filters ~ ·
search history ○ · hashtags ✗ · recent searches ○.

## 12. Privacy, security and settings

Privacy checkup ○ · default audience ✓ · who can see your friend list ✓ (nobody) · who
can look you up by email or phone ✗ (nobody can; there is no directory) · search engine
indexing ✗ (nothing is public) · timeline and tag review ○ · off-Facebook activity ✗ · ad
preferences ✗ · download your information ✓ · access your information ~ · deactivate ○ ·
delete with grace period ~ (wipe is immediate) · two-factor ✗ (no account; the key is the
account) · login alerts ~ (security notices on key changes and new devices ✓) · recognised
devices ✓ (your devices) · app passwords ✗ · apps and websites ✗ · Accounts Center ✗ ·
language ○ · dark mode ✓ · data saver ○ · video autoplay ○ · location history ✗ · manage
activity ~ · take a break ○ · quiet mode ○ · time-on-app dashboard ○ · daily reminder ○ ·
parental supervision ✗ · face recognition, removed by Facebook · key verification ✓
(safety numbers; Facebook has it only in Messenger) · backup with passphrase ✓ · social
recovery ✓ · device linking ✓.

## 13. Safety and reporting

Report a post, comment, profile or message ~ (to the sphere's admins ✓; to a platform ✗)
· support inbox ✗ · block ✓ · restrict ○ · hide ✓ · mute ✓ · hidden words ✓ · fact-check
labels ✗ · sensitive-content warnings ~ (blur-until-tapped ✓, classifiers ✗ by decision)
· "AI info" labels ~ (media origin score ✓, reads metadata only) · community standards
and account strikes ✗ · suicide and crisis resources ○ · account status ✗.

## 14. Accessibility and small comforts

Automatic alt text ✗ · custom alt text ✓ · captions ✗ · screen reader support ~ · text
size ○ · reduced motion ○ · high contrast ○ · keyboard shortcuts, web only · poke ○ ·
year in review ○ · your topics ✗ · QR codes ✓ · chat heads ○.

## Reading the marks

Roughly: of some 330 items, Spheres has about 120 built or partly built, could build
about 130 more without touching its premise, and cannot build about 80 because they
need a public audience, a central index, a ranking model, an advertiser, or Meta's
servers. The ✗ column is the product definition, not a backlog; `feature_review.md` §A4
says the same thing in one paragraph.

---

# Plan for the ○ column

Written 11 October 2026. Nothing here changes the premise: no public audience, no
central index, no ranking, no ads. Every item is scoped to contacts or a sphere, signed
by its author, sealed in transit, and stored encrypted. The ✗ column stays ✗. The items
"by decision" in `feature_review.md` (post approval, communities, story drawing, GIF
search, pixel classifiers, link previews, presence) stay out unless that decision is
revisited on its own.

**Before any of it: the soak test and a signed release.** A day of ordinary use on three
devices, then `build_release.sh`. Feature work on top of an unproven transport is how
this repo got its invisible bugs the first time.

Effort is in working days at the pace of 11 October 2026 (one person with an agent, tests
and docs included). Each parity milestone follows the house rules: a new message kind
gets a model field, a sender, a receiver switch case, a `describeMessage` entry, a parser
test and a fuzz entry; a stub never reports success; README and CLAUDE.md change in the
same commit.

| # | Milestone | What lands | Wire | Days |
|---|---|---|---|---|
| P1 ✓ 11 Oct 2026 | **Comments and reactions, the daily loop** | The seven reaction kinds on posts, reactions on comments, edit a comment with history, delete and hide comments, pin a comment, comments off or members-only per post, subscribe to a post, reaction and reply notifications, newest-first and threaded views polished | `post_react` carries a kind; `comment_edit`, `comment_hide`, `comment_pin`, `post_settings` sealed to the sphere and checked against roles on receipt | 5 |
| P2 ✓ 11 Oct 2026 | **Profile** | Bio, pronouns, nickname, name pronunciation, cover photo, featured photos, the about fields (work, education, city, hometown, relationship with partner mention, family, languages, websites, hobbies, quotes, life events), temporary profile picture, "updated their picture" post into chosen spheres, per-field audience (all contacts or named spheres), view-as, legacy contact tied to social recovery | `profile` envelope grows typed fields and per-field audience; cover and featured photos ride as blobs | 6 |
| P3 | **Composer and media** | Coloured text backgrounds, feeling and activity, crop, rotate, filters, text and stickers on photos, video trim and thumbnail choice, life events, "ask for recommendations" as a poll variant, reshare a post into another sphere with attribution (author's signature travels; the author can forbid resharing), pin to profile, trash with 30-day restore, bulk archive and trash | `post_reshare` with the original envelope embedded; `post.allowReshare` | 7 |
| P4 | **Stories** | Boomerang, layouts, selfie mode, quiz and slider stickers, feeling sticker, link sticker (no preview), hide from named contacts, archive, highlights on the profile | Story payload gains sticker kinds; highlights are a local list plus a `profile` field | 4 |
| P5 | **Messaging comforts** | Files of any type, chat themes and nicknames (local), chat emoji, ignore, scheduled messages, original-quality media toggle, chat bubbles on Android, profile notes, a vanish-mode preset over disappearing messages, avatar stickers once avatars exist | Files are blobs with a name and type; the rest is local or reuses existing kinds | 5 |
| P6 | **Sphere governance** | Membership questions answered in the join request, rules shown on join, units and guides, files, badges and expert marks, keyword alerts for admins (local), suspend for a period, welcome posts, post topics, admin automation for the rules already built (auto-mute on N reports, auto-expire invites) | `sphere_join` carries answers; rules, units and topics are signed sphere items | 6 |
| P7 | **Events** | Co-hosts, recurring events, ticket links, "interested" alongside going, event photos, reminders, ICS export, a map link that opens the user's own map app | `event_rsvp` gains a state; the rest rides existing post kinds | 3 |
| P8 | **Friends and feed** | Restricted contacts (see only named spheres), snooze for 30 days, take a break, friendversary from local history, favourites feed, hide a post, birthday cards, autoplay and data-saver settings | Local, except restricted contacts, which is an audience list on the sender | 3 |
| P9 | **Settings, safety, accessibility** | Privacy checkup walkthrough, tag review before a mention shows on your profile, pause (deactivate) that keeps keys, language, quiet hours, time dashboard, daily reminder, restrict a contact (their comments visible only to them), crisis resources, text size, reduced motion, high contrast, a screen-reader pass over every screen, search history, notification dots, year in review, poke | Restrict is `comment_hide` applied automatically; the rest is local | 5 |
| P10 | **Avatars and on-device extras** | A cartoon avatar editor with stickers; on-device translation of posts and comments with a downloadable model (opt-in, never bundled, following the nudity-model decision) | Avatar is a blob in `profile`; translation stays on the device | 6 |

About 50 days in all. P1, P8 and P7 are the cheap, visible wins and go first; P2 and
P3 are the big ones people notice; P10 is optional.

## What is deliberately not in the plan

Everything ✗, and the "by decision" items above. Two near-misses worth naming:
reshare *outside* the audience (✗, it is reposting to strangers), and link previews
(off: fetching a preview tells a server which link was shared; a sender-generated
preview carried in the post is the version that could return). Automatic alt text
and captions need a model; they go the way of translation in P10 if ever.
