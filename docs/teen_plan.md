# Spheres for teenagers: cool, and good for them

*Plan, 25 October 2026. Follows §12.6 of `rebuild_plan.md` (desires served, not
exploited; the app carries words and never supplies them) and the decisions on minors
(an age question and a legal floor; a guardian's say over new contacts, never a reading
of messages). Nothing here is built yet.*

## What a teenager wants, and what the others sell them

What they want: a small group that is theirs. A place the parents are not. To make
things with friends. Inside jokes. To try on who they are. To not be caught: no
screenshots, no leaks, no being made fun of for a message sent at the wrong moment.
To be good at something and have the group know. To talk late. To keep the year.

What the big platforms turn each of these into: a streak that punishes a day off; a
follower count; a "best friends" ranking; a face filter that teaches them their face is
wrong; "active now" and "seen" that make silence an accusation; an endless feed of
strangers who are prettier; location shared with everyone; a public like count under
their first photo.

Spheres refuses every one of those by construction, and the refusals are the first
feature: **no public audience, no follower count, no like count, no streak, no "active
now", no face filter, no ranking of friends, no feed beyond the people they know.** The
rest of this plan is what to build in the space that leaves.

## The crew

A **crew** is a sphere kind for a close group, three to about eight, which is the size a
teenager's real world has. It is an ordinary sphere with a different set of toys, and
with its own defaults: flashes go to the crew unless said otherwise, view receipts and
typing are off, media sent in it is protected by default (shown while held, never saved
or forwarded, no screenshots), and the crew can agree lights-out hours when nothing
arrives. "What is said here stays here" is a property of the code, not a promise.

## The features

Each one says what it is for, which trap it avoids, and what travels between phones.
Every page or message in them goes through the writing guide where words are needed.

**1. Our words.** The crew's dictionary: the words and phrases only they use, each with
who said it first and when, added by anyone, edited by the crew. Inside jokes made into
a thing they own. *Avoids:* nothing to count or compare; it is a keepsake. *Travels:*
small sphere items, `crew_word`.

**2. The quote board.** "Things we said": a line someone said, posted by another, shown
only once the person quoted has said yes. A board of a year of being funny. *Avoids:*
exposure without consent; the approval is private and a refusal leaves no trace.
*Travels:* a draft envelope to the quoted person, an approval back, then one sphere item.

**3. Pass the camera.** A chain: one person takes one photo, then passes the camera to
the next, who has a day. It ends when it has gone round, and the chain is the keepsake.
No filters, no retakes, one shot. *Avoids:* the streak: it ends, and a missed day ends it
gracefully rather than breaking anything. *Travels:* one `chain` post and one media page
per turn with the "next" name.

**4. The story we wrote.** One line each, in turn, nobody seeing the whole until it ends;
the crew's own exquisite corpse. Or a zine: each person a page, bound at the end. Or a
playlist of titles with a hummed bar as a voice note, no streaming service, no link.
*Avoids:* endlessness: every one of these has a last turn and becomes a thing. *Travels:*
turn pages like occasion pages.

**5. The capsule.** Write to the crew, or to yourself, to open on a date: the end of the
year, the last day of school, the eighteenth birthday. Nothing shows until then.
*Avoids:* nothing timed to pull; it opens once, on a day they chose. *Travels:* a post with
an `opensAt`, the welcome-book mechanism from the occasions plan.

**6. Study hall.** The crew sits down together: a shared timer, everyone's notifications
quiet for the stretch, a line of what each is working on, and at the end one card, "we
did fifty minutes, Tuesday". The next one is a new card; nothing accumulates into a
score. *Avoids:* streaks and leaderboards: no total, no best, no chain of days. *Travels:*
a `study` post with start, length and who joined; the quiet is each phone's own.

**7. Pass a note.** A text message read like a note passed in class: shown while held,
gone when let go, never kept on the other phone. Protected media, for words. *Avoids:*
the screenshot and the forward. *Travels:* a chat message with the protection flag the
media already has.

**8. Sleep on it.** When a message is written late, or hot, a button beside send: "send
in the morning". It goes at an hour the person set, and until then it can be taken back.
*Avoids:* the regret the other apps profit from. *Travels:* nothing new; scheduled
messages exist.

**9. Not now.** Every request, invitation and page asked of a teenager has "Not now" as
a first-class answer that sends nothing and shows nothing to the other side. Learning to
decline without an excuse is a thing the app can teach by making it ordinary. *Avoids:*
pressure from what others can see. *Travels:* nothing.

**10. The mask.** A different drawn avatar and a different name for each sphere, chosen
by the person, so the crew's version of them and the family's can differ, as they do in
life. The profile already cuts fields per sphere; this adds the face. *Avoids:* the face
filter: a drawn face is theirs to invent, not a photograph corrected toward a standard.
*Travels:* the profile envelope, cut per contact as now.

**11. Who knows me.** An evening's game: each member writes three questions about
themselves; the crew answers; the results are read out once and kept by nobody. *Avoids:*
rankings: there is no scoreboard after the evening. *Travels:* quiz pages, discarded at
the end by rule.

**12. The scrapbook.** The crew's year, from what they made: the chains, the stories, the
words, the capsules opened, the study halls, laid out by month, exportable by hand. Made
only from things they chose to make, never from what they looked at. *Avoids:* anything
derived from behaviour. *Travels:* nothing; it is assembled on each phone.

**13. I'm not okay.** One tap to one person the teenager chose in advance, carrying no
words, only a set of concrete offers the other person can answer with: *come over*,
*call me now*, *stay on the line while I sit with you*, *tell someone for me*. The
helplines screen sits behind it. *Avoids:* the app speaking for anyone: these are
actions, not sentences. *Travels:* a small sealed envelope `reach` to one person.

**14. Lights out.** Hours the crew agreed, when nothing arrives from the crew and
"goodnight" is the last page. Set by them, not by a parent, and visible to them as a
thing they decided. *Avoids:* the night-time pull. *Travels:* a crew setting in the
sphere's info.

**15. The eighteenth.** At the age the person set, the app offers everything they made,
exported, and the choice to keep the account or close it with nothing left behind. A
rite of passage and a proof that it was always theirs. *Avoids:* the lock-in. *Travels:*
nothing.

## The guardian, done right

A guardian is a role on the teenager's identity, agreed when the account is made, not a
member of their spheres. A guardian **approves new contacts and invite links** for the
minor and **sees nothing else**: no messages, no posts, no activity, no "last seen".
The teenager sees exactly what the guardian can see, on a screen called "What my
guardian sees", which is a short list. A guardian who wants more is told no by the app,
in words, and the teenager is told that too. At the age the law sets, the role ends by
itself and the teenager is told.

Why this and not monitoring: a watched teenager moves to an app that does not watch,
and the one safety that holds is the one they will keep. The door is the only thing
worth guarding.

## Defaults for a minor's account

Flashes to the crew by default; receipts and typing off; media protected in crews; no
one outside a sphere can reach them (true for everyone); "Not now" everywhere; lights
out suggested at account creation, set by them. Nothing else differs from an adult's
account: the same encryption, the same keys, the same ownership.

## Implementation plan

*Written 25 October 2026. Five milestones with exit criteria and the tests each owes.
Sizes are focused part-time days. Every milestone touches the message path, so the
second rule of `CLAUDE.md` applies throughout.*

### The model, in one place

**Age is a fact on the identity, entered once.** `Identity.birthDate` (the profile's
`birthday` is a shown field with an audience; this one is the legal fact and is never
sent anywhere). `models/minor.dart` (pure): `MinorRule.floorFor(country)` (13 to 16 as
the law sets, 13 where unknown), `isMinor(birthDate, country, now)`, `endsAt`. Country
is asked once, as a choice, not read from the phone.

**A guardian is a signed bond between two identities.** The minor, at onboarding or in
Settings, scans the guardian's contact code; the minor's device sends `guardian_offer`
(a sealed direct envelope carrying the bond: minor key, guardian key, the age the role
ends at, signed by the minor); the guardian's device shows what the role is and is not,
and answers `guardian_accept` (the same bond, signed by the guardian) or nothing. The
bond, signed by both, is stored on both devices (`spheres_guardian_v1`, sealed) and is
what the minor's device enforces against. There is at most one guardian; a second
replaces the first by the same handshake. At `endsAt` the minor's device drops the bond
and tells the guardian with `guardian_ended`.

**The door is the only thing guarded.** On a minor's device, `ContactService.approveRequest`
and the invite-link join path refuse unless `GuardianService.allows(contactKey)`: a
signed `guardian_approval` from the guardian naming that exact key. The minor's device
asks with `guardian_ask` (the contact's key and the name the contact claims, nothing
else); the guardian's device shows it and answers `guardian_approval` or
`guardian_refusal`; a refusal is shown to the minor as "not now" from the guardian, with
no reason, and the request stays declinable by the minor at any time. Nothing else on
the minor's device consults the guardian, and the code has no path that sends the
guardian content: the test for this milestone is that the guardian's device can open no
envelope type from the minor except the seven named here.

**"What my guardian sees" is a screen made from the code**, not a promise: it lists the
seven envelope types and renders their fields, and a test asserts the list equals the
set the guardian handler accepts.

**A crew is a `SphereKind.crew`.** A group sphere with a size the UI holds to about eight
(the model does not refuse a ninth; a crew is a kind of care, not a limit) and defaults
read by the composer, the flash sheet, the chat and the notification service:
`SphereInfo.crew` (a new block in the admin-published info: lights-out start and end,
media protected by default, receipts off, flashes to the crew). Lights-out is applied
on each phone to that crew's notifications and sends; a message sent in the hours is
held and goes at the end of them, like "sleep on it".

**Made things are occasion posts.** The chain, the story, the zine, the playlist, the
capsule and study hall are `occasion` posts with their own `event` values and page kinds,
on the model of `achievements_plan.md` (C1 provides the post, the page item, the clock and
the chapter). Turn-taking is a rule on the pages: the post names an order; a page from
the wrong signer for the turn is kept but shown as out of turn; the turn passes when the
page arrives or when the turn's day ends, whichever first; the post ends when the order
is spent or a turn's day ends with nothing, and the end state is written by the host's
device as a `post_edit`.

**Private approvals are direct envelopes.** The quote board's approval (`quote_ask`,
`quote_ok`), the mask (the profile envelope, already cut per contact), and `reach` (the
one-tap with its offers) travel sealed to one person. Nothing in them reaches a sphere.

**Nothing is kept that the rule says is not.** A note is a chat message with the
protection flag and is never written to the receiver's store (the same path as
view-once, which already does this); "who knows me" pages are dropped at the game's end
by every device; study hall keeps one card per session and no field that sums.

### Milestones

| # | Milestone | Size | What lands | Exit criterion |
|---|---|---|---|---|
| T1 | **Age, guardian, crew, not now** | 4 | `models/minor.dart`; the age and country question at onboarding and in Settings for an existing identity; `GuardianService` with the bond handshake, `guardian_ask`/`approval`/`refusal`, the gate on `approveRequest` and the invite join, `guardian_ended`; the guardian's screen for asks; "What my guardian sees"; `SphereKind.crew` with `SphereInfo.crew` defaults and lights-out held sends; "Not now" as the first button on every request, invitation and page, sending nothing. | Three phones: a minor's device cannot add a contact until the guardian's phone approves it; a refusal shows "not now" and no reason; the guardian's phone holds and can open nothing of the minor's content (asserted by the envelope list); a crew's flash goes to the crew by default and a message in lights-out hours goes at their end. Tests: the floor per country, `isMinor` at the boundary, the bond signed by both, the gate, the envelope allow-list equal to the screen, lights-out holding. |
| T2 | **Pass a note, sleep on it, I'm not okay** | 2 | Protected text on the view-once path, shown while held and never stored on the receiver; "send in the morning" beside send, on `scheduleMessage` at the person's hour, taken back from the drafts page until then; the `reach` envelope with its four offers answered by one tap on the other side and the helplines behind it. | A note read on the second phone is nowhere in its store after it is let go; a morning send is taken back; a reach reaches one person and their answer comes back as an action line. Tests: the note never persisted, the hour, the single recipient, the offers as an enum with no free text. |
| T3 | **Our words, the quote board, the mask** | 3 | `crew_word` sphere items with who and when, edited by any member, listed in the crew's info screen; `quote_ask`/`quote_ok` and the board as sphere items shown only with the approval attached (the quoted person's signature over the quote); a drawn avatar and a name per sphere on `UserProfile`, cut by `ProfileSharing.payloadFor` so each contact gets the face for the spheres they share. | A quote posted without the quoted person's yes is never shown on any phone; the family sees one face and the crew another. Tests: the board refuses an unsigned quote; a refusal leaves no item; the per-sphere face in the profile cut. |
| T4 | **Pass the camera, the story we wrote, the capsule, study hall** | 4 | On C1's occasion post: `chain` with a day per turn and one media page per turn, no retake (the composer offers no edit step for a chain photo); `story` and `zine` turn pages; `playlist` pages of title and a hummed voice note; the capsule as an occasion with `opensAt` far ahead, held by `ChapterService`; `study` with the shared timer (each phone's own clock from the post's start), quiet for the stretch through the notification service, and one card at the end with no sum anywhere. | A chain goes round three phones with a day each and ends gracefully when one turn passes with nothing; a story reads whole only at its end; a capsule opens on its date; a study hall quiets three phones and leaves one card. Tests: turn order and the out-of-turn page, the graceful end written as an edit, the far `opensAt`, no field that sums study time. |
| T5 | **Who knows me, the scrapbook, the eighteenth** | 3 | The game as an occasion whose pages every device discards at its end (a rule in the receive path keyed on the event); the crew's scrapbook assembled on the phone from made things by month, exported by hand through the chapter export; the `endsAt` moment: the guardian bond dropped, the export of everything the person made and the pages others consented to, and the choice to keep or close with the backup's delete path. | Nothing of a game remains on any phone after its end; a scrapbook contains only made things and no view history; at the set age the guardian is told the role ended and the export names only consented pages. Tests: the discard rule, the scrapbook's sources, the ended bond, consent gating of the export. |

Depends on `achievements_plan.md` C1 for T4 and T5; T1 to T3 stand alone. T1 is first
because everything about minors depends on knowing who is one, and the guardian gate is
the one safety that must exist before a teenager is invited.

### Rules every milestone keeps, as tests

- **The guardian sees the door and nothing else.** The guardian handler's accepted types
  equal the "what my guardian sees" list; every other type from the minor is dropped
  unopened, and a test sends each kind the app has.
- **Nothing counts.** No streak, no total, no rank: a test greps the teen features'
  models for any field that sums across sessions and expects none.
- **Everything ends.** Each made thing has an end state reachable by clock alone, tested
  with a clock a day ahead.
- **Silence shows nothing.** No "has not taken their turn", no "has not answered"; a test
  asserts the views list only what arrived.
- **"Not now" is free.** It sends nothing; a test asserts no envelope leaves on a decline.
- **Words are the person's.** Every page composer opens through the writing guide; the
  reach carries an enum, never text.

### What is reused, not written

`SphereKind` and `SphereInfo` for the crew and lights-out; the contact request and
invite-join paths for the gate; sealed direct envelopes for every private exchange;
view-once's never-stored path for notes; `scheduleMessage` for the morning; the drawn
avatar and `ProfileSharing` for the mask; the occasion post, page item, clock and chapter
from C1 for everything made; `ChapterService` and the chapter export for the capsule and
the scrapbook; the backup's delete path for the eighteenth; the writing guide for every
page.

## Not doing, by decision

Streaks of any kind; a "best friends" ranking; face filters; "active now"; location to a
sphere by default; a public anything; reading a minor's messages for anyone, including
the operator; any feature that makes a day off cost something.
