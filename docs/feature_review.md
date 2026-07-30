# Feature review — what to build

**Date:** 30 July 2026
**Companion to:** `docs/feature_landscape.md` (what Facebook and Instagram have)

This is a working document. It exists to be argued with and marked up, not admired.
Sorted so the top of each table is where the value is.

## How to read it

Two categories, because they fail differently. **Category A** is what people do every day —
if these are missing or clumsy the app feels broken even when nothing is wrong. **Category
B** is safety, security and efficiency — where failure is invisible until it matters, and
then matters a great deal.

**Status** — `Built` · `Partial` · `Missing` · `N/A` (cannot exist without a public
audience, ad auction or central index — see the landscape doc).

**Effort** — `S` under a day · `M` a few days · `L` a week or more · `XL` needs design first.

---

## Category A — what users do every day

### A1. The daily loop
The handful of actions that make up most of a session. Everything here is either built or
cheap, which is the good news.

| Feature | What people expect | Status | Effort |
|---|---|---|---|
| Send/receive a message | Instant, ordered, never lost | **Built** | — |
| Read receipts, typing | Know it arrived and they're replying | **Partial** — receipts yes, typing no | S |
| Photo in a chat | Pick, send, appears | **Built** | — |
| Voice note | Hold, talk, release | **Built** | — |
| React to a message | Long-press, emoji | **Missing** — reactions exist on posts, not messages | S |
| Reply to a specific message | Quote-reply in thread | **Missing** | S |
| Post to a sphere | Text/photo, choose audience | **Built** | — |
| Like / react to a post | One tap | **Built** | — |
| Comment | Add, see others | **Built** — but flat, no threading | S (threading) |
| Story: post, view, reply | 24h, see who watched | **Built** | — |
| **Save a post** | Bookmark to collections | **Missing** | S |
| Search my stuff | Find a message or post | **Built** | — |
| Voice/video call | One tap from a chat | **Built** | — |

**The three cheapest wins are message reactions, message replies and saves.** All are
local-only, all are used dozens of times a day, and their absence is felt immediately.

### A2. Composing
| Feature | Status | Effort | Note |
|---|---|---|---|
| Multi-photo post (carousel) | **Missing** | M | Very common; model and UI change |
| Edit a post after publishing | **Missing** | S | With an "edited" marker |
| Delete own post | **Built** | — | |
| Alt text on images | **Missing** | S | Accessibility; also cheap |
| Co-authored post | **Missing** | M | Natural fit — both are sphere members |
| Draft / scheduled send | **Missing** | M | Outbox already does the hard part |
| Pin a post in a sphere | **Missing** | S | |
| Video posts | **Partial** | L | Uploads untranscoded, no thumbnail, 24MB cap |
| Story stickers: poll, quiz, question, countdown, slider | **Missing** | M each | High engagement, no server needed |
| Story text/drawing tools | **Missing** | M | |
| GIFs | **Missing** | — | **N/A** as normally built — GIPHY is a central index |

### A3. Organising and finding
| Feature | Status | Effort | Note |
|---|---|---|---|
| Search messages, posts, spheres, people | **Built** | — | Local, no server sees the query |
| Saves / collections | **Missing** | S | |
| Archive a sphere or chat | **Missing** | S | Hide without leaving or deleting |
| Mute a sphere or chat | **Partial** | S | Contact mute exists; not per-sphere |
| Pin a chat to the top | **Missing** | S | |
| Unread counts / badges | **Partial** | M | Needs a real notification service |
| Memories / on-this-day | **Built** | — | |
| Media gallery per sphere | **Missing** | M | "All photos in this sphere" |

### A4. Cannot exist here
Explore · hashtags · global search · algorithmic recommendations · trending · follower
counts · verification · reposting to strangers · Remix · Live · Marketplace · Dating ·
ads · shopping · creator monetisation · Google indexability.

Not a backlog. Anything user-facing that implies these are coming should be corrected.

---

## Category B — safety, security, efficiency

### B1. Security — where we are ahead
| Property | Spheres | Facebook / Instagram |
|---|---|---|
| Message content encryption | XChaCha20-Poly1305, always | **Instagram: removed 8 May 2026.** Messenger: default since Dec 2023 |
| Forward secrecy on DMs | Yes, ratcheted | No |
| Who can see the social graph | Nobody — mailbox addresses derive from shared secrets | The operator, entirely |
| Local storage | Encrypted at rest | Not equivalently |
| Identity | Keypair, no phone or email | Real-name policy, phone often required |
| Audience | Member-scoped by construction | Public by default |

Worth stating plainly in the app, because it is the actual product argument — and it is
structural, not a promise.

### B2. Security — where we are behind
| Gap | Impact | Effort |
|---|---|---|
| Never independently audited | Unknown unknowns | — (external) |
| No post-compromise security | Stolen DM chain state follows the conversation forward | XL — needs a DH ratchet |
| No forward secrecy on sphere content | Epoch key opens everything in that epoch | L |
| Mailbox addresses don't rotate | Operator sees a long-lived pair is talking | L — needs a lookback window |
| Concurrent multi-device unsupported | Two devices reuse ratchet keys | XL |
| No safety-number / key verification UI | Cannot detect a swapped prekey out of band | **M — do this** |
| Screenshot notification or prevention | Stories offer neither | M |

**Key verification is the notable one.** Everything rests on getting the right X25519 key,
and there is currently no way for two people to confirm out of band that they did. Signal
solves this with a comparable safety number; it is a modest amount of work and closes a
real machine-in-the-middle gap.

### B3. Safety between people — the [M] gap, and your answer to it
Facebook and Instagram answer harassment with a central authority: reporting queues,
account status, appeals, the Oversight Board, impersonation takedowns. **We have no such
authority and should not pretend otherwise.** Your framing — leave freely, vote to remove,
transferable admin — is the right substitute, and §3 works it through.

| Feature | Status | Effort | Note |
|---|---|---|---|
| Leave a sphere | **Built** | — | Keys discarded; the strongest remedy and always available |
| Block a person | **Built** | — | |
| Remove a member | **Built** (admin only) | — | Epoch bump + re-key; cryptographically real |
| **Vote to remove** | **Missing** | L | §3.3 |
| **Transfer admin** | **Partial** | M | Can promote; cannot demote self or hand over cleanly |
| **Admin succession** | **Missing** | M | §3.5 — a sphere can currently be orphaned |
| Mute a member within a sphere | **Missing** | S | Hide their content without removing them |
| Hidden-words filter | **Missing** | M | Meta runs this on-device; fully portable |
| Report to *the sphere* | **Missing** | M | Flag content to admins — no external authority needed |
| Nudity blurring | **Missing** | L | On-device at Meta; needs a local model |
| Teen/parental supervision | **Missing** | XL | Largely depends on age assurance we cannot do |

### B4. Efficiency — mostly unmeasured
Nothing here has been profiled on a device; these are architectural expectations, not
measurements.

| Concern | Current design | Risk | Effort |
|---|---|---|---|
| Connection count | One WebSocket **per contact per purpose** (chat, feed, call) | **High** — battery and sockets scale linearly with contacts | **L — multiplex** |
| Battery | Persistent sockets, no backoff when idle | Medium | M |
| Data usage | Posts fan out **once per member** | Medium — an *n*-member sphere sends *n* copies | L |
| Storage growth | Media cached forever; no cap | Medium | S |
| Startup time | Loads everything into memory | Medium as history grows | M |
| Offline | Outbox retries; feed reads local | **Good** | — |
| Large spheres | Untested beyond a handful | Unknown | — |
| Battery/data settings | None | Users expect control | M |

**Multiplexing the seven relay connections into one is the highest-value efficiency work,**
and it has been outstanding since Phase 2.

---

## 3. Sphere governance — the exhaustive design

You asked for this to be thorough, and it is the piece where a decentralised design has to
do real thinking rather than copy.

### 3.1 Principle
No central authority exists, so every power must come from either **the key** (you can
always leave, and always stop being able to read) or **the members** (collective decisions,
signed and verifiable). Nothing may depend on someone adjudicating.

### 3.2 Roles
| Role | Powers |
|---|---|
| **Owner** | One per sphere. Everything an admin can do, plus transfer ownership and delete the sphere. Cannot be voted out — see 3.5 |
| **Admin** | Invite, remove, promote to admin, rename, edit description, pin |
| **Member** | Post, comment, react, invite (if enabled), leave, propose and cast votes |
| **Read-only** | Sees content, cannot post — for broadcast-style spheres |

Currently only admin/member exist and the creator is just an admin. Owner should be
distinct, because "who can hand over the keys" and "who can kick people" are different
questions.

### 3.3 Voting to remove — design
Removal is the one power that most needs legitimacy, because it is the only one that is
irreversible for the person on the receiving end.

**Proposal.** Any member may propose removing another. Signed, carries a reason, broadcast
to the sphere.

**Eligibility.** Everyone except the proposer and the subject votes. **The subject cannot
vote on their own removal** — otherwise a two-person sphere deadlocks permanently.

**Threshold.** Configurable per sphere at creation, defaulting to **a simple majority of
those who vote, with a quorum of one third of members**. Both numbers matter: a threshold
without a quorum lets three people in a sphere of fifty remove someone.

**Window.** Votes stay open **72 hours**. People are offline; a vote that closes in an hour
disenfranchises anyone asleep. If quorum is not met when the window closes, the proposal
**fails** — silence is not consent.

**Execution.** When it passes, any admin (or, if none is online, any member) performs the
epoch bump and re-key. The membership operation carries the collected signed votes so
every member can verify the outcome independently rather than trusting the executor.

**Abuse.** Rate-limit proposals — one open proposal per subject at a time, and a cooldown
after a failed one, so a majority cannot harass a minority with repeated votes.

**Admins.** In small spheres a vote is heavy. Keep admin unilateral removal, but make it
**visible to all members** — an admin action that nobody can see is indistinguishable from
a central authority. Spheres above a configurable size could require a vote even for
admins.

### 3.4 Transferring control
- Owner nominates a successor; **the successor must accept** before it takes effect,
  otherwise ownership can be dumped on someone who has stopped using the app.
- Transfer is a signed membership operation like any other, so it is verifiable.
- Demoting yourself from admin should be possible — currently it is not.

### 3.5 Orphaned spheres — the case a decentralised design must answer
**If the only owner loses their phone, the sphere is currently stuck forever.** Nobody can
invite, remove, or re-key. This will happen.

Options, in order of preference:

1. **Multiple admins by default.** Encourage a second admin at creation. Simple, no
   protocol change, solves most cases.
2. **Inactivity succession.** If the owner has not published a signed heartbeat for *N*
   days, admins may collectively promote a new owner. Needs a signed heartbeat, and needs
   care: an owner on holiday must not lose their sphere.
3. **Member vote to elect a new owner** once the owner is provably inactive, using the same
   machinery as 3.3.

Recommend 1 immediately and 3 later. Avoid 2 alone — inactivity is not the same as absence,
and getting the threshold wrong hands spheres to whoever is most online.

### 3.6 Membership lifecycle — the full set
| Operation | Status |
|---|---|
| Create sphere | **Built** |
| Invite | **Built** — explicit accept required |
| Accept / decline invitation | **Built** |
| Leave | **Built** |
| Remove (admin) | **Built** — epoch bump and re-key |
| Promote to admin | **Built** |
| **Demote an admin** | **Missing** |
| **Demote self** | **Missing** |
| **Transfer ownership** | **Missing** |
| **Propose / vote removal** | **Missing** |
| **Rename, edit description** | **Missing** |
| **Sphere icon or colour** | **Missing** |
| **Member-visible audit log** | **Missing** — who did what, when; the substitute for Account Status |
| **Rejoin after leaving** | **Missing** — needs a fresh invitation today |
| **Delete a sphere** | **Missing** — distinct from everyone leaving |
| Read-only members | **Missing** |
| Invite permissions (admins only vs anyone) | **Missing** |

**The audit log deserves attention.** With no central authority, the check on admin power
is that every member can see what admins did. It is also cheap: the signed membership
operations already exist, so it is largely a rendering job.

---

## 4. Suggested order

**First — the daily loop.** Message reactions, message replies, saves, comment threading,
per-sphere mute, pin a chat. All small, all felt immediately. This is what makes it feel
like a real app rather than a demo.

**Second — governance.** Ownership as a distinct role, transfer with acceptance, demotion,
rename, audit log, second-admin-by-default. Mostly extensions of machinery that already
works, and they close the orphaned-sphere hole before anyone hits it.

**Third — efficiency.** Multiplex the connections, cap the media cache. Before spheres get
large, not after.

**Fourth — safety within a sphere.** Mute a member, hidden words, report-to-admins,
voting-based removal.

**Fifth — composing.** Carousels, editing, alt text, story stickers.

**Throughout — key verification.** Small, and it closes a genuine hole.

Deliberately last: post-compromise security, sphere forward secrecy, address rotation,
multi-device. All real, all XL, none blocking day-to-day use.
