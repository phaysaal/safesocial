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
| Read receipts, typing | Know it arrived and they're replying | **Built** | S |
| Photo in a chat | Pick, send, appears | **Built** | — |
| Voice note | Hold, talk, release | **Built** | — |
| React to a message | Long-press, emoji | **Built** | — |
| Reply to a specific message | Quote-reply in thread | **Built** | — |
| Post to a sphere | Text/photo, choose audience | **Built** | — |
| Like / react to a post | One tap | **Built** | — |
| Comment | Add, see others | **Built** — threading already rendered | — |
| Story: post, view, reply | 24h, see who watched | **Built** | — |
| **Save a post** | Bookmark to collections | **Built** — with collections | — |
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
| Saves / collections | **Built** | — | `/saved`, private to the device |
| Archive a sphere or chat | **Missing** | S | Hide without leaving or deleting |
| Mute a sphere or chat | **Built** | — | Muted spheres drop out of the feed |
| Pin a chat to the top | **Built** | S | Long-press a chat to pin |
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

~~Currently only admin/member exist and the creator is just an admin.~~ **Done.** Owner is
now distinct. Two clarifications the implementation forced:

* **Only the owner may demote another admin**; anyone may demote themselves. Letting any
  admin demote any other turns a disagreement into a race decided by whichever operation
  reaches the most devices first.
* **Read-only members are still missing.** `SphereKind.broadcast` already limits posting by
  role, so the gap is a per-member flag rather than a new concept.

### 3.3 Voting to remove — **built**
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
after a failed one, so a majority cannot harass a minority with repeated votes. Both are in;
the cooldown is seven days.

Two things the implementation settled that the design left open:

* **A decided vote closes early.** Once the outstanding votes could not change the result,
  waiting out the remaining hours only delays a conclusion everyone can already compute.
* **In a small sphere a single voter decides**, because a third of two is one. Stated
  outright in a test rather than left as an accident of the arithmetic. Demanding more from
  a group that size produces a rule that deadlocks instead, and anyone unhappy can leave.

**Still hard-coded:** the 72-hour window, the one-third quorum and the simple majority are
constants, not per-sphere settings. Making them configurable means putting them in the
signed membership operation so every device agrees on the numbers — worth doing, but it is
a wire change and was not worth bundling here.

**Admins.** In small spheres a vote is heavy. Keep admin unilateral removal, but make it
**visible to all members** — an admin action that nobody can see is indistinguishable from
a central authority. Spheres above a configurable size could require a vote even for
admins.

### 3.4 Transferring control — **done**
- Owner offers; the successor accepts and **executes the change themselves**, carrying the
  owner's signed offer as proof. Doing it in that direction means a transfer completes even
  if the outgoing owner has already gone — often exactly why they are handing it over.
- Offers **expire after seven days**. There is no cancellation: a revocation message a
  member simply failed to receive would be worse than a bounded window.
- Demoting yourself is now possible, and so is stepping down as admin.
- **An owner who leaves hands ownership on automatically** — to the longest-serving admin,
  or the longest-serving member if there is no other admin. Leaving has to stay
  unconditional, so succession is derived rather than negotiated; every device computes the
  same answer from the member list.

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

**Option 1 is done**, in three places: the create screen asks for a second admin whenever
the sphere has any members, the sphere page warns an owner who is the only admin, and an
owner leaving hands ownership on rather than orphaning the sphere. Option 3 waits on the
voting machinery in 3.3.

### 3.6 Membership lifecycle — the full set
| Operation | Status |
|---|---|
| Create sphere | **Built** |
| Invite | **Built** — explicit accept required |
| Accept / decline invitation | **Built** |
| Leave | **Built** |
| Remove (admin) | **Built** — epoch bump and re-key |
| Promote to admin | **Built** |
| **Demote an admin** | **Built** — owner only |
| **Demote self** | **Built** |
| **Transfer ownership** | **Built** — offer, accept, seven-day expiry |
| **Propose / vote removal** | **Built** — proposal, votes, quorum, proof-carrying execution |
| **Rename, edit description** | **Built** |
| **Sphere icon or colour** | **Missing** |
| **Member-visible audit log** | **Built** — 200 entries per sphere, on the sphere page |
| **Rejoin after leaving** | **Missing** — needs a fresh invitation today |
| **Delete a sphere** | **Missing** — distinct from everyone leaving |
| Read-only members | **Missing** |
| Invite permissions (admins only vs anyone) | **Missing** |

**The audit log deserves attention.** With no central authority, the check on admin power
is that every member can see what admins did. It is also cheap: the signed membership
operations already exist, so it is largely a rendering job.

Built, with one honest limitation: the log records what *this device applied*, so it is
each member's own record rather than a shared one. Two members who were offline at
different times hold different slices and neither is authoritative. The screen says so.

Implementing this also turned up a real hole. Inbound authority was a single question —
is the author an admin? — which meant an admin could attach any member list they liked to
any operation. Operations now recompute the expected membership from state already held
and reject anything that does not match, so an author can trigger a change but not define
one. A rename can no longer smuggle in a new member.

---

## 4. Suggested order

**First — the daily loop.** ~~Message reactions, message replies, saves, comment threading,
per-sphere mute, pin a chat.~~ **Done.** Comment threading turned out to be already
rendered. Typing indicators and the chat list's pin ordering followed; the whole
block is now closed.

Typing indicators are opt-out and reciprocal, matching how story view receipts
already work here: switching them off stops your own signals *and* hides other
people's, so the setting cannot be used to watch without being watched. Outbound
signals are throttled to one every three seconds, inbound ones expire after
seven, and they never enter the outbox — a typing signal that arrives late is
worse than one that never arrives.

**Second — governance.** ~~Ownership as a distinct role, transfer with acceptance,
demotion, rename, audit log, second-admin-by-default, voting-based removal.~~ **Done.**
Remaining in this block: deleting a sphere, rejoining after leaving, read-only members,
invite permissions, and per-sphere voting thresholds.

**Third — efficiency.** Multiplex the connections, cap the media cache. Before spheres get
large, not after.

**Fourth — safety within a sphere.** Mute a member, hidden words, report-to-admins,
voting-based removal.

**Fifth — composing.** Carousels, editing, alt text, story stickers.

**Throughout — key verification.** Small, and it closes a genuine hole.

Deliberately last: post-compromise security, sphere forward secrecy, address rotation,
multi-device. All real, all XL, none blocking day-to-day use.
