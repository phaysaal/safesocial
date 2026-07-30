# Facebook & Instagram feature landscape

**Compiled:** 30 July 2026
**Purpose:** a reference for deciding what Spheres should build, and — more usefully —
what it *cannot* build and should stop implying it will.

## Confidence, stated up front

The two halves of this document are not equally reliable.

- **Instagram (§2)** was researched against Meta's newsroom, Mosseri's posts and tier-one
  tech press during compilation. Items sourced only from SEO aggregator roundups are
  marked *(agg.)* and should be treated as unconfirmed.
- **Facebook (§3)** is **not web-verified.** The research pass for it failed partway and
  the session's search budget was exhausted before it could be redone, so it is written
  from model knowledge with a January 2026 cutoff, plus three items confirmed from Meta's
  newsroom on the compile date. Treat structure as reliable and specifics as stale until
  someone re-checks them. Anything load-bearing should be verified before acting on it.

## Dependency flags

The point of this exercise is separating "not built yet" from "cannot exist here".

| Flag | Meaning |
|---|---|
| **[S]** | Needs a central server doing global search, discovery or ranking |
| **[$]** | Needs advertising or commerce infrastructure |
| **[P]** | Needs a public audience — people beyond your own contacts |
| **[M]** | Needs a central moderation and appeals authority |
| **[—]** | No fundamental dependency; portable to a member-scoped, serverless design |

The **[M]** axis emerged from the research and is easy to miss. A large part of what makes
these platforms feel *safe* — reporting flows, account status, appeals, impersonation
takedowns, priority queues for schools — depends on a central authority, not on discovery
or ads. A design with no such authority has to answer that separately, and "we have no
moderation because we have no public audience" is only a partial answer: harassment
inside a small group is still harassment.

---

## 1. What this means for Spheres

### Already built
1:1 and group messaging with reactions, replies, edit, unsend, delivery receipts;
voice/video calls; ephemeral stories with view receipts and replies; posts with comments
and reactions; albums; media sharing; contacts and QR exchange; block/mute; local search;
data export; encrypted backup; social recovery.

### Buildable, not built — roughly in order of value
- **Saves / collections** — pure local state, one of the most-used features on both platforms.
- **Chronological "favourites" view** — trivial given spheres already scope the feed.
- **Story stickers**: poll, quiz, question, countdown, emoji slider. Self-contained, high
  engagement value, no server needed.
- **Carousels** (multi-image posts) and **alt text**.
- **Co-authored posts** — natural fit: a post authored by two members of a sphere.
- **Post editing** with an edited-at marker.
- **Pinned posts / pinned messages.**
- **Scheduled sending** — local timer plus the existing outbox.
- **Hidden-words filtering** — Meta runs this on-device, so it is portable as-is.
- **Nudity blurring** — also on-device at Meta; needs a local model, which is a real cost.
- **Quiet hours / time limits** — purely local.
- **Threaded comment replies** (currently flat).

### Cannot exist without abandoning the premise
Explore, hashtags, global search, algorithmic recommendation, trending audio, follower
counts, verification, reposts to strangers, remix, broadcast channels, Live, Marketplace,
Dating, ads, shopping, creator monetisation, Google indexability. Every one requires a
public audience, a central index, or an ad auction. **These are not a backlog.** The
landing page should not imply they are coming.

### The uncomfortable one
**Moderation and appeals [M].** No Oversight Board, no reporting queue, no impersonation
takedown. Within a sphere, the only remedies are the ones already built — removal with
key rotation, and blocking. That is coherent, but it should be stated deliberately in the
threat model rather than left as an omission.

---

## 2. Instagram — verified inventory (July 2026)

### 2.1 Identity & profile
| Feature | Notes | Dep. |
|---|---|---|
| Username / display name / photo | Globally unique namespace | **S** |
| Bio, links in bio (up to 5) | Custom bio fonts are a paid perk | — |
| Profile Cards | Shareable card with QR code | — |
| Profile banners, interests | Pill banners under bio; up to 5 interest topics *(agg.)* | **S** |
| Personal / Creator / Business accounts | Creator gets full music library; Business gets catalogue and API | **$ P** |
| Creator tools for all public accounts | Since 1 Mar 2026: insights, 75-day scheduling, trending audio | **S P** |
| Legacy verification / Meta Verified | Paid tier ~$11.99–14.99/mo adds ID verification and impersonation monitoring | **$ P M** |
| **Instagram Plus** | Launched 4 Jun 2026, $3.99/mo — Story Spotlight, 48h stories, searchable viewer list, 6 pins | **$** |
| Multiple accounts (up to 5), Accounts Center | Cross-app identity hub | — |
| AI Creator label | Optional account-level AI disclosure (May 2026) | **P** |

### 2.2 Social graph
Followers/following **[P]** · mutuals · **Close Friends** (and a more exclusive "Secret
Friends" in test) · private/public toggle **[P]** · **Restrict** (shadow-limits a harasser
without notifying them) · block · **block all linked and future accounts** **[S]** · mute ·
remove follower · hide-story-from · activity-bubble hiding.

### 2.3 Posting
Single photo/video · **carousels up to 20** with per-slide captions and post-publish
reordering · captions · alt text · tagging people **[P]** / products **[S$]** / location
**[S]** · **Collab** co-authoring up to 5 **[P]** · native scheduling (25/day, 75 days) ·
post-publish editing including **replacing audio on live posts** (Jul 2026) · archive ·
30-day Recently Deleted · **grid reordering** (Jun 2026) · pinned posts · **Trial Reels**
(publish to non-followers first) **[SP]** · **Instants** — camera-only disappearing photos
to close friends, also a standalone app (May 2026).

### 2.4 Stories
24h ephemeral (48h paid) · **interactive stickers**: poll, quiz, question, emoji slider,
countdown, Add Yours, Frames, Reveal · utility stickers: link, music **[$]**, location
**[S]**, mention, hashtag **[S]**, GIF **[S]**, cutouts, auto-captions · Create Mode,
Layout, filters · **Story editing after posting** (May 2026) · Highlights · Close Friends
stories · replies and quick reactions · **Story Comments** — public comment section, a
real shift from DM-only replies **[P]** · viewer list **[P]** · **screenshot prevention**
on view-once (Jun 2026) · insights **[SP]**.

### 2.5 Reels
Up to 3 minutes · multi-clip camera, speed, timer, green screen, voiceover · **native
teleprompter** · licensed audio **[S$]** · **Remix** **[P]** · templates **[S]** ·
Meta-only AR effects **[S]** (third-party filters died with Meta Spark, Jan 2025) ·
**Series** — episodic Reels with a profile hub (Jun 2026) **[SP]** · tap-to-pause,
2× speed · **Edits** standalone editor app.

### 2.6 Feed & discovery — almost entirely [S]
Algorithmic home feed · **Following** and **Favourites** chronological feeds (still exist,
but cannot be set as default) · Explore · Reels tab · **Friends tab** · **Blend** — shared
algorithmic feed inside a DM · **Instagram Map** · multimodal search **[S$]** · hashtags
(following them was removed Dec 2024) · suggested posts · **"Your Algorithm"** — inspect,
weight and reset inferred topics, reached the main feed Jun 2026 · **Watch History** ·
Google indexability **[SP]** · TV apps · **navigation redesign** (Feb–Mar 2026) moved
Create out of the bottom bar.

### 2.7 Messaging
> **E2EE was removed globally on 8 May 2026.** The opt-in encryption from Dec 2023 is
> gone; Meta cited low adoption and pointed users at WhatsApp. Note the causality:
> server-side AI summarisation, translation and in-DM product recommendation are
> structurally incompatible with E2EE, and Meta chose those. Users were told to download
> anything they wanted to keep.

1:1 and groups up to 250 · message requests (one text-only message from non-followers) ·
**Hidden Words on-device** · chat folders **[P]** · edit within 15 min · unsend, forward,
pin · scheduled messages · reactions and quote-replies · read receipts · typing indicators
· voice notes with **AI voice effects [S]** · calls up to 8 with screen sharing · vanish
mode · one-time-view media · themes, nicknames, fonts, in-chat games · **Notes** — 60-char
24h status for mutuals, now with comments **[P]** · **Meta AI in DMs** — thread summaries,
translation across 99 languages, shopping recommendations **[S$]** · broadcast channels
**[P]**. Cross-app messaging with Messenger was removed in Dec 2023 and has not returned.

### 2.8 Engagement
Likes (hideable counts) · comments, editable 15 min, now with **image comments** (Jul 2026)
· pinned comments · **saves and collections** — heavily weighted in ranking, and fully
portable · **sends to DM — the single most weighted distribution signal in 2026** ·
reshare to story **[P]** · **native Reposts** with a profile tab (Aug 2025) **[SP]** ·
no true quote-post · Super Hearts **[$]**.

### 2.9 Creator & business — all [$] and/or [P]
Insights (redesigned Apr 2026; "Views" replaced Impressions Apr 2025; KPI triad is views,
reach, **sends**) · professional dashboard · Shops with off-platform checkout · **affiliate
links, up to 30 products per Reel, Meta takes no cut** (Mar 2026) · ads and Advantage+ ·
branded content and Partnership Ads · **Creator Marketplace** · subscriptions ($0.99–99.99,
2M+ active) · Stars/gifts · Live badges · bonuses · broadcast channels · Live (restricted
to 1,000+ followers since Aug 2025).

### 2.10 Safety & wellbeing
**Hidden Words** (on-device) · comment controls and **Limits** during pile-ons · comment
warnings · Restrict/block/mute · **Teen Accounts** — private by default, sleep mode,
strictest content tier · **13+ content rating**, global across IG/FB/Messenger 17 Jun 2026
**[S]** · "Limited Content" tier · age assurance including **AI visual age estimation**
(Jun 2026) **[S]** · **Family Center** (May 2026) · parent algorithm insights · **distress
alerts** extended to Meta AI chats (Jul 2026) **[S]** · time limits, Take a Break, Quiet
Mode · sensitive content control **[S]** · **on-device nudity blurring** · anti-sextortion
measures · School Partnership 48h priority queue **[M]** · Account Status, Support
Requests, Oversight Board **[M]** · 2FA and login activity (**still no passkey support**)
· AI content labelling.

### 2.11 Data & account
Download Your Information · Your Activity dashboard · bulk-delete interactions · search
and watch history · ad preferences **[$]** · off-Meta activity — **from Jul 2026 this feeds
content recommendations, not just ads** · deactivate vs delete (30-day grace) · **Meta AI
photo training is on by default; opting out is manual** (Jul 2026).

### 2.12 Notable removals
E2EE in DMs (May 2026) · third-party AR filters and Meta Spark (Jan 2025) · Notes on feed
posts (Mar 2025) · Basic Display API (Dec 2024) · following hashtags (Dec 2024) ·
Impressions and Plays metrics (Apr 2025) · Live for accounts under 1,000 followers (Aug
2025) · native Shops checkout (mid-2025) · the **Muse** @-mention image feature, pulled
within days after backlash (Jul 2026) · square profile grid (Jan 2025, no toggle back).

---

## 3. Facebook — inventory, NOT web-verified

> Written from model knowledge with a **January 2026 cutoff**. The research pass failed and
> the search budget was spent before it could be repeated. Structure should be sound;
> specifics may be stale. Three items were confirmed from Meta's newsroom on 30 Jul 2026
> and are marked **[confirmed]**.

### 3.1 Confirmed on the compile date
- **Seller app for Marketplace** (24 Jul 2026) — standalone app for managing listings **[S$]**
- **Facebook Verified** (24 Jul 2026) — a verification offering **[$PM]**
- **"Connecting Real People on Facebook"** (23–24 Jul 2026) — authenticity initiative **[SM]**

### 3.2 Identity & profile
Real-name profile with work, education, relationship, life events · profile and cover
photos, avatars · **multiple professional profiles** · granular per-field audience controls
(public / friends / friends except / specific / only me) · legacy contact · Meta Verified
**[$PM]**.

### 3.3 Social graph
Bidirectional **friends** (5,000 cap) · **followers** for public posting **[P]** · **friend
lists** including Close Friends and Acquaintances · **Restricted list** (sees only public
posts) · block, snooze (30 days), unfollow-but-stay-friends · **People You May Know**
**[S]** · friend requests with privacy scoping.

### 3.4 Sharing
Text, photo, video, link posts with previews · **albums** and shared albums · tagging
people and places **[S]** · feeling/activity · check-in **[S]** · life events ·
**audience selector per post** · scheduling (Pages) · post editing with edit history ·
memories/On This Day · saved posts · **Marketplace** listings **[S$]**.

### 3.5 Feed
Algorithmic News Feed **[S]** · **Most Recent** chronological view · **Favourites** feed ·
reactions (Like, Love, Care, Haha, Wow, Sad, Angry) · threaded comments with ranking ·
shares to feed, story or message **[P]** · hide, snooze, unfollow, "why am I seeing this"
· **Reels** **[S]** · **Stories** · **Live** **[P]**.

### 3.6 Messenger
1:1 and group chats · **E2EE became the default for personal chats in Dec 2023** — note
this is the opposite direction to Instagram, and worth re-verifying given the Instagram
reversal · disappearing messages · reactions, replies, forwarding, unsend · voice and
video calls, **Rooms** · themes and nicknames · message requests · communities.

### 3.7 Groups & Pages
Public/private groups (visible or hidden) · admin and moderator roles · membership
questions · post approval, keyword alerts, muting, anonymous posting · group rules,
insights, badges, events, files, units · **Pages** with roles, insights, CTAs, shops
**[S$]** · **Events** — public/private, ticketing, co-hosts, recurring **[S]** for
discovery.

### 3.8 Distinct product surfaces — all [S] and mostly [$]
Marketplace · Dating · Gaming and Instant Games · Fundraisers and donations · Jobs (varies
by region) · News and Watch (heavily wound down).

### 3.9 Discovery, safety, data
Global search across people, posts, groups, pages, marketplace **[S]** · hashtags **[SP]**
· recommendations **[S]** · granular notification controls · **reporting and Support
Inbox** **[M]** · Oversight Board **[M]** · parental supervision · **Download Your
Information** · Activity Log · **Off-Facebook Activity** **[$]** · ad preferences **[$]** ·
deactivate vs delete (30-day grace) · Privacy Checkup · Security Checkup, 2FA, login alerts.

### 3.10 Wound down or removed (pre-cutoff)
News Feed renamed to Feed (2022) · **News Tab** discontinued in several markets (2023–24) ·
Facebook Live Shopping (2022) · standalone Gaming app (2022) · Facebook Watch de-emphasised
· Nearby Friends and Facebook Campus discontinued · Timeline "poke" mostly vestigial ·
Notes discontinued (2020) · Facebook Credits, Deals, Places, Questions, Offers all long
retired.

---

## 4. Two observations worth keeping

**Meta is retreating from in-app commerce and doubling down on discovery.** Checkout, the
Shop tab and Live Shopping are all dead; affiliate link-out returned in 2026. The platform
keeps the two things it cannot outsource — the recommendation engine and the ad auction —
and hands fulfilment to merchants. Those two are precisely what a member-scoped network
cannot replicate, which is a clean way to describe what Spheres is trading away.

**Instagram removing E2EE is the clearest statement of the trade-off in the whole
document.** Encryption and server-side AI features are mutually exclusive, and a company
whose revenue depends on understanding content will choose the latter every time. That is
the actual argument for a project like this one — stronger than any privacy-policy claim,
because it is structural rather than a promise.
