# Achievements: announced, witnessed, kept

*Plan, 25 October 2026. Follows §12.6 of `rebuild_plan.md` (desires served, not
exploited). Nothing here is built yet.*

## Why

A business person has things worth telling: a new post, a degree passed, a project
shipped, a company founded, ten years at the firm. LinkedIn made the telling into a
stage with a counter under it, and the counter is the product. Spheres has no stage:
the people told are the people who know you, in the sphere you chose. That changes
what an announcement can be. It can be a small ritual with an end, made by people who
know the person, and something the person keeps. The family has achievements too: a
child's exam, a grandparent's eightieth, a first marathon.

The rule, in short: no counts anyone else sees, no reward on a slot-machine schedule,
nothing timed to pull, every ritual ends, nothing about anyone that they did not choose
to show.

## What exists to build on

- `life_event` posts and `ProfileAbout.lifeEvents` with a per-field audience.
- Signed posts (`authorSig`), co-authored posts, scheduled posts, "on this day" memories.
- Flashes with countdown and question stickers; comments and reactions; "ask the sphere".
- Pictures that wait for the tagged people's consent (`media_lock`).
- Appreciation delivered once a day at the person's hour (`AppreciationService`).
- Protected media; the Self sphere; events with RSVP and calendar export.

## The shape

An **achievement** is a `life_event` post with a `kind` in its payload (below), a date,
and the people and spheres it names. It is signed by the achiever and, when a team did
it, co-signed by every co-author. It is shown in the feed with an **announcement**
specific to its kind, answered by the sphere through a **toast** that ends, and kept by
the achiever as a **chapter** on the profile and as a **card** they may export.

### Kinds, each with its own announcement

Every heading below is a prompt shown faintly, not a field to fill: the person writes
freely and may ignore all of them. "Achievement" is the word of this plan, not of the
screen; the screen says "a moment" or "news".

| Kind | Announcement on the card | What it asks of the sphere |
|---|---|---|
| New role, promotion | **A first page.** The opening page of a working notebook, written by the achiever under three headings: what I'm joining, what I hope to contribute, what I'm bringing with me. A promotion writes "what I'm now responsible for" instead, so the distinction is the work, not the rank. Drawn as a nameplate: name, title, organisation, like a door sign. | A toast |
| Degree, exam, certification | **The last question.** The card opens with one question that once baffled the person and that they can now answer, then their short answer and the qualification. A seal in the corner: institution and date, the logo's three wave bands as the ribbon. | A toast; "what I remember of the long nights" from those who were there |
| Project shipped, published | **The maker's plate.** Its name, what now works, the problem it solves, one detail its makers are proud of, and every name on it, co-signed. The card is the team's, not one person's, and appears once in the sphere with all signatures. | A toast; co-authors each add one panel, "the piece I made possible", equal in size, in an order the team approves |
| Award, recognition | **The citation and the unseen scene.** The citation verbatim in the display face, the achiever's name under it as read at a ceremony, and beside it one scene the person chooses: the rejected draft, the kitchen table where the work happened. | A toast |
| Business founded, first client | **The founding letter.** Signed, to a chosen sphere: who this is for, what we promise, what we will decline to do. It stays as a dated document to revisit, with any later update written separately and never rewriting the original. Co-founders sign. | A toast; the sphere may pledge a first word of mouth, kept private to the founder |
| Work anniversary | **A letter across time.** At a new role the person may write a short letter to their future self and pick the date and hour to reopen it; at the anniversary they read it and may append "what surprised me". A ring for each year on the card, no number, counted on the viewer's tap. | A single line each: "the thing I'd keep from working with you" |
| A child's result or event, posted by a parent | **The child's chosen headline.** Before anything is published the child, when a member, picks the headline, approves the wording and the audience, and decides on a photo, or on publishing at all; "I finally felt confident presenting" may replace the parent's score. The card is plain and warm, no seal, no plaque: the child's pride is not a trophy for the parent's sphere. Nothing says a child declined. | A toast with a line to the child, delivered to the child's device when they are a member |
| Personal milestone (marathon, a book finished, a language learnt) | **A finish-line field note.** Three prompts: where it got difficult, what helped, what I want to remember; one chosen photograph or a hand-drawn route. Times and measurements stay off the shared card. | A toast |
| Years together, a birthday round number | **The kitchen-table interview.** A family tradition kept as a template of three questions the family wrote once; the achiever answers them, in writing or in their own voice, and the answers are the card. No obligation to do it next time. The year count on tap. | A group card composed before the day (ask-the-sphere) |

Each announcement is a single animation played once, respecting reduce-motion, with its
own small sound off by default. None loops. None waits for a tap to "collect" anything.

### The toast, as a closed book

The sphere's answer. Each member may add **one page**, once, within a window the achiever
set (a day by default): a line, or a **witness postcard** that begins "I remember when…"
and tells one specific moment that gives the achievement its context, in a colour the
writer picks, signed. Pages are not shown as they arrive. At the hour the achiever chose,
or when the window closes, the book opens: the achiever's announcement and their own
closing reflection are always in it, so there is a keepsake even if nobody wrote, and
then every page that was given. The achiever sees who wrote what; the sphere sees that
the book was opened and, on tap, the pages, so the ritual is shared and ends. There is no
count anywhere, no roster of who is still to write, no empty slots: names are the
measure. A page can be private to the achiever, marked so by its writer.

A page may also carry a **practical gift**: a practice interview after the degree, an
audience for a rehearsal before the new role, a meal after the project. It has a scope,
is accepted by an explicit reply, and is never a task on a list; nobody sees whether it
was accepted but the two of them.

This is the appreciation rule applied to words. The window closing is the end state.

### The chapter

Every achievement the person keeps becomes a **chapter** on their profile, in order,
under a per-field audience like every profile field: work chapters to work spheres,
family chapters to family, some to nobody. A chapter carries the card and the toast it
received. The profile's "view as" shows exactly which chapters each sphere sees. This is
the private, true version of a résumé, and it is the person's to show or not.

### The case card, for work

In a client or work sphere an achievement can be told as a **case card**: the problem as
it stood, the result delivered, one approved piece of evidence, what the person learned.
A client or colleague may add a **signed attestation** to that exact version. It is
professional context for people already allowed to see it, and it is what "a word for
you" becomes when it is about a piece of work: a deliberate, signed statement, never a
count, never copied to another sphere by itself.

### The drawer

Each sphere may keep a **drawer**: achievements its members chose to place there, in an
order they chose, each in the form of its kind, a founding letter beside a maker's plate
beside a field note. It ends with its last item. It can be exported as a sealed package
for the sphere's own keeping. It has no badges, no targets, no automatic nominations.

### The card, kept

The achiever can **export the card** as an image or a PDF for their own use: a certificate
of the moment, signed by them, listing the sphere that witnessed it and, if they choose,
the toast's lines with their writers' consent. It leaves the app only by the person's
hand. Nothing in it is public and nothing links back.

### Anniversaries

"On this day" already resurfaces old posts to their author. An achievement's anniversary
resurfaces privately to the achiever with its card and book, and offers, once, to tell
the sphere: "a year since Al's first client". Offered, not posted; the achiever decides.
The sphere may open a short book again. The achiever may also, at the time of the
achievement, nominate it for a future "on this day" and **write its caption now**:
"remember the people who helped us finish this"; when the day comes it shows the card and
those exact words and then ends. Selection is the person's, never derived from what they
looked at.

### A word for you

LinkedIn's endorsements are counts of a word. The served version: a member can write
**a word for** someone, a line about them as a colleague or a friend, delivered to that
person alone, kept by them, and shown on their profile only if they choose, to the spheres
they choose, with the writer's name and the writer's consent to be shown. No tally, no
skill list, no public page of praise. A business person who wants references has them,
in their own hand to show.

### Team achievements

A co-authored achievement is one card in the sphere with every signature; each co-author
may add their line of what they did; the toast is to all of them; each keeps the chapter.
Nobody gets a bigger name than anyone else on the plaque.

### Professional use without a public audience

- A client sphere sees "project delivered" with the plaque; a work sphere sees the same
  with the internal names; the family sees "it shipped" with a photo. One achievement,
  three cuts, like the profile.
- Exported cards and chapters are what someone shows in an interview, from their phone,
  by their choice.
- "A word for you" is a reference the person holds.

## Reminders and the writing companion

People forget. The companion exists for that, and for the person who wants to say
something and cannot find the words, under the second principle of §12.6: it carries
words and never supplies them.

**The reminder.** Occasions that someone declared, a birthday entered in their own
profile, a moment they shared, an anniversary they announced, are brought to mind at
the hour the person set for appreciation, as one quiet line in that same delivery:
"Today: Al's birthday. Mira's first client, a year ago." Nothing is a task. Nothing
counts what was not done. Nothing is derived from who has been quiet with whom unless
the person turns that on by name.

**The companion**, opened from the reminder or from any moment's card. It never writes a
sentence. It does four things:

- **Shows the occasion** and what the person already knows: the moment's card, the last
  thing they said to each other if the person wants it shown, a photo they share.
- **Asks**, in the order of a real message, questions only this writer can answer, shown
  faintly and skippable: *How do you want to begin?* *What did they do this year that
  you noticed?* *What do you remember about them and this?* *What do you wish for them?*
  Each answer is the person's own words in the draft; the questions are not in it.
- **Notices, once and gently**, when the draft has nothing particular to the person in
  it: "This could be said to anyone yet. A memory, or their name, would make it theirs."
  A local check (a name, a "remember", a "when", a place), never a judgement of quality,
  and never blocking.
- **Offers the voice.** Any message, page or postcard can be spoken instead of typed and
  travels as a voice note; a spoken page in the book is the warmest page in it.

*Built on 25 October 2026 as `WritingGuide` and the "Write for an occasion" sheet in a
chat, with the questions, the notice and the voice hand-over; the reminder line is still
to come.*

What it will not do: offer phrases to pick from, fill a greeting, propose an emoji, send
on one tap, or rank the draft. Sending needs words the person wrote or spoke. The
"Congrats!" button does not exist here, and the reaction glyph that does exist is a
gesture, not words.

## Celebrations, by event

*Added 25 October 2026.* Facebook celebrates everything the same way: balloons, a wall,
"share your love". LinkedIn celebrates everything the same way too: a banner, a
"celebrate" reaction, forty "Congrats". Both are effects applied to a post. An organic
celebration is not an effect. It is **made of the people**, it has a **host**, it
happens at a **moment**, and it leaves a **keepsake**. So every event below is written
in those four parts: what the host does, what the sphere brings, when it opens, what
remains. No two events look alike, because no two are alike in life.

The visual grammar, so the kinds stay one family: things you could hold. A nameplate, a
seal, a letter, a table, a route, a wall, a key, a door. Paper and wood, not glass and
neon. One slow movement on first view, as if setting the thing down. Any sound is a real
voice someone recorded, never a chime. Names everywhere, numbers nowhere.

### Professional

**An award.** *Host:* the citation, verbatim, and the choice to have it read: by the
achiever in their own voice, or by a colleague who asks to read it, as at a ceremony.
Beside it, the unseen scene. *The sphere brings:* "I was there when": each member who
saw any part of the road writes the moment they saw, one sentence, in their hand. Those
who were not there may bring a single word they would use for the person's work, kept
private to the achiever. *Moment:* the reading opens at the achiever's hour; the
sentences arrive with it. *Keepsake:* the award hangs on the achiever's **wall**, a
section of the profile per sphere, like the wall of an office: the citation, the
reading, the sentences, in the frame the achiever picked. *Unlike:* no banner, no
"celebrate" count. A reading and witnesses.

**A new role, a promotion.** *Host:* the first page (what I'm joining, what I'm
bringing); a nameplate drawn like a door sign, with the old title fading as the new one
settles, once. *The sphere brings:* two lists that meet on the card. From the people of
the old place, **what to pack**: one thing to take with you. From the people of the new
place, if they are in a sphere, **what to expect**: one true thing about where you are
going. *Moment:* the card is sealed until the first day, and opens that morning at the
hour the person set. *Keepsake:* the nameplate becomes a chapter; the two lists stay on
its back. *Unlike:* nobody announces it for you, and the first day is the moment, not
the day the form was filled.

**A degree, an exam, a certification.** *Host:* the last question, and **the names of
those who helped**, written by the achiever; each person named gets a private line,
"you were thanked", with the words. *The sphere brings:* for a family, the **gown
photo** composed together from pictures members submit, the collage the app already
makes; for colleagues, "what I remember of the long stretch". *Moment:* the hour the
achiever set, often the evening of the result. *Keepsake:* the seal on the chapter and
the collage. *Unlike:* the celebration starts with thanks going outward, not
congratulations coming in.

**A project shipped, a thing published.** *Host:* the maker's plate, co-signed, and a
**launch log**: three to seven moments from the making, photos or lines, in order, laid
as a strip; every co-author may add to it. *The sphere brings:* the **first users'
register**: a member who used or read the thing writes one sentence of what it did for
them. A client sphere sees the plate and the register; the family sees the strip. *Moment:*
the plate is posted when the thing is live; the register stays open a week and then
closes. *Keepsake:* the plate and the register together, in every co-author's chapter.
*Unlike:* credit is a list of names of equal size, and the measure is what it did for
people, written by them.

**Something started: a business, a practice, a studio.** *Host:* the founding letter,
signed, with who it is for, what we promise, what we will decline. *The sphere brings:*
**seeds**, private to the founder: a concrete thing each person can do for the start,
an introduction, a first order, a Saturday of help, each accepted or declined by the
founder alone; and for the family, a photo of the door, the desk, the first sign.
*Moment:* the letter goes out on the day the founder chooses; the seeds arrive at the
founder's hour. *Keepsake:* the letter, dated, with any later update written separately.
*Unlike:* no "follow the page"; a letter and help offered.

**A work anniversary.** *Host:* the letter across time, written at the start and
reopened now, with "what surprised me" appended. *The sphere brings:* **the desk**: each
colleague places one object on it, a photo or a word, that reminds them of the person;
the desk fills during the day and is seen whole at the hour. *Moment:* the day itself,
declared by the person, never computed from a start date. *Keepsake:* the desk, in the
chapter. *Unlike:* nobody is prompted to "congratulate Sam on five years"; Sam chose to
mark it, and the colleagues brought objects, not a button.

**Retirement, a last day.** *Host:* **the key**: the person writes what they learned, as
pages, and hands them over; the sphere keeps them. *The sphere brings:* **what we keep**:
one line each of what stays behind because of this person. *Moment:* the last day's
afternoon. *Keepsake:* the pages and the lines, bound. *Unlike:* the achiever gives, the
sphere receives; the reverse of a feed.

### Family and personal

**A birthday.** *Host:* nothing; the birthday person is the guest. A member opens **the
table**. *The sphere brings:* each person brings one thing to the table: a photo, a
memory, a song's name, a voice of a few seconds, a drawing by a child. The things are
laid around a round table, one place each, and nobody sees the table until it opens.
The candles are the people. *Moment:* the morning of the day, at an hour the host set.
*Keepsake:* the table, as it was, in the birthday person's chapters. *Unlike:* no wall
of "HBD", no cake drawn by an app. A table laid by people.

**A child's result, a first.** *Host:* the child, who chooses the headline and whether
there is a card at all; the parent is the scribe. *The sphere brings:* lines **to the
child**, not about them, delivered to the child's device if they are a member; and
**who taught you**, the child's own thanks, each named person told privately. *Moment:*
the evening. *Keepsake:* the child's, in their own profile. *Unlike:* the child is the
host of their own moment; the parent's sphere is the guest.

**A marathon, a summit, a thing finished.** *Host:* the field note and **the route**,
drawn or traced. *The sphere brings:* each member places themselves at a point on the
route with a line: "I'd be at the thirtieth kilometre with water", "at the top with the
flask". The route fills with people. *Moment:* the day after, when the legs hurt.
*Keepsake:* the route with the people on it. *Unlike:* no time, no pace, no comparison.
People along a road.

**A wedding, years together.** *Host:* two. *The sphere brings:* **two chairs**: each
partner's people write to the other partner, not to the couple; the letters cross. A
family may add the kitchen-table interview, answered by both. *Moment:* the day, or the
evening before. *Keepsake:* two bound sets of letters, one in each chapter. *Unlike:*
nobody writes to "the happy couple"; each is addressed as a person by the other's people.

**A new child.** *Host:* the parents, with **the name's story**, a few lines on why the
name. *The sphere brings:* the **welcome book**: first words to someone who cannot read
them yet, to be given on a birthday the parents choose. *Moment:* the book closes when
the parents say; it opens years later. *Keepsake:* the book, held for the child.
*Unlike:* it is written for the child, not posted at the parents.

**A move, a new city.** *Host:* the new door. *The sphere brings:* **pins**: places they
know in the new city, a bakery, a doctor, a walk, each a line; and a date for the
housewarming if the host opens one. *Moment:* the first week. *Keepsake:* the pins as a
list the person keeps. *Unlike:* usefulness over applause.

**Hard news: a loss, an illness.** *Host:* none, and nothing is required of the person.
A member opens **the kettle**. *The sphere brings:* concrete help on a rota, meals,
lifts, an hour with the children, each a slot taken by one person, seen only by the
person helped and the helpers; and **a candle**, lit quietly, whose lighters only the
bereaved can see. No words needed from anyone, and no count of candles anywhere.
*Moment:* now, and for as long as the rota runs. *Keepsake:* none offered; grief is not
a chapter unless the person makes it one later. *Unlike:* no "sending love" reactions
in public; a rota and a candle.

### What every one of these has that the big apps do not

- **A host and guests.** Somebody opens the occasion; the others bring. The app is the
  room, never the host.
- **A moment.** Things open at an hour a person set. Nothing trickles.
- **Made of people.** Sentences, voices, objects, places, letters. Never an effect.
- **A keepsake the person owns**, in their chapters, cut per sphere, exportable by hand.
- **Silence allowed.** Who did not bring anything is nowhere.
- **The achiever often gives first**: thanks, the key, the letter. The direction of the
  feed is reversed.

### What is shared with the writing guide

Every "brings" above is a page, and every page is written through the guide's
questions for that occasion, so a line to the child, a seed to the founder and an object
on the desk each get their own two or three questions and never a sentence to send.

## What travels between phones

- The achievement: a signed `life_event` post with `payload['achievement']` (kind, title,
  organisation, date, co-authors, the consent lock for a named child). Sealed per sphere
  as every post is.
- A toast line: a feed item `toast` (post id, text, private flag), one per member per
  achievement, sealed to the sphere. The closing of the window is a local clock, not a
  message.
- A page of the book: a feed item `toast` (post id, text, kind line or postcard with a
  colour, private flag, an optional practical-gift scope), one per member per
  achievement, sealed to the sphere. The window's close is a local clock, not a message;
  a gift's acceptance is an ordinary direct message.
- A word for you, and an attestation on a case card: a sealed direct envelope `word_for`
  (text, and the case card's version when it attests one) to one person.
- A child's approval: a private sealed draft to the child and their decision back, before
  anything reaches the sphere; the sphere sees only what was approved.
- A letter across time and a future caption: stored by their author; nothing travels
  until the day, and then only if they choose to tell the sphere.
- Anniversaries: nothing travels unless the achiever tells the sphere, and then it is an
  ordinary post.
- Chapters: part of the `profile` envelope, cut per contact as every field is.
- Nothing about who viewed, how often, or when.

## Checked against the rule

| Rule | Where it bites | How it is kept |
|---|---|---|
| No variable-time rewards | Toast lines dripping in | Lines held and delivered together at the hour or the window's end |
| No numbers shown to everyone | Toast counts, years, endorsements | Names instead of counts; years counted on the viewer's tap; words kept privately |
| Nothing timed to pull | Anniversary nudges | Shown to the achiever when they open the app; offered, not pushed |
| Loops end | Open-ended congratulation threads | One line per member, a window that closes, a card that is final |
| No pressure from what others see | Who did not toast | Never shown; a toast lists who did, never who did not |
| Nothing derived from behaviour | Suggested achievements | None; every achievement is typed by the person |

## Rejected

- **Streaks and levels** (achievements as a game). Variable reward, no end.
- **"X people are celebrating"** live counter. A number for everyone, timed to pull.
- **Suggested achievements from calendar or messages.** Derived from behaviour.
- **Sharing a card outside Spheres with a link back.** A public audience by the back door.

## Implementation plan

*Written 25 October 2026. Six milestones, each with an exit criterion and the tests it
owes. Sizes are focused part-time days. The second rule of `CLAUDE.md` applies to every
milestone: all of them touch the message path.*

### The model, in one place

**An occasion is a post.** `Post.kind = 'occasion'`, signed like every post, sealed per
sphere like every post, so it rides the feed, the sync archive, deletion, editing, the
spheres-after-sending change and the memories, with nothing new in transport. Its
`payload['occasion']`:

```json
{
  "event":   "award | newRole | degree | project | founded | anniversary | retirement |
              birthday | childMoment | milestone | together | newChild | move | hardNews",
  "host":    "<identity key, or the child's key for childMoment>",
  "opensAt": "<ISO instant the pages are revealed>",
  "closesAt":"<ISO instant after which a page is late>",
  "fields":  { "...per event, see the catalogue; every one optional free text..." },
  "brings":  "line | postcard | object | seed | place | point | chair | slot | candle | reading"
}
```

`models/occasion.dart` (pure): the event catalogue (its fields, what it asks the sphere to
bring, its card), `Occasion.tryParse` that drops anything short of a whole one, and the
clock rules: `isOpen(now)`, `isLate(page, now)`. The writing guide's `Occasion` enum is
folded into it so one list names every event.

**A page is a feed item.** `occasion_page`, received the way a comment is: attributed to
the signer, one per member per occasion (a later one from the same signer replaces the
earlier), kept by every member of the sphere, archived for sync like everything else.

```json
{ "type": "occasion_page", "post_id": "...", "page": {
    "id": "...", "kind": "line | postcard | object | seed | place | point | chair | slot | candle | reading",
    "text": "...", "colour": "...", "media": "<blob ref>", "audio": "<blob ref>",
    "at": "<ISO>", "slot": "<slot id, for rotas>", "point": 0.0 } }
```

A page the writer marks private goes instead as a **sealed direct envelope**
`occasion_page` to the host alone, the way a `profile` envelope travels, so the sphere
never holds it. A candle is always private. A reading (a colleague's voice reading the
citation) is a page with audio.

**The moment is a clock, not a message.** Every device holds `opensAt` and shows nothing
of the pages before it; the host's device raises one notification at that instant through
the feed's one-minute sweep. A page arriving after `closesAt` is kept and shown below the
fold as late, never dropped.

**The keepsake is local first.** `ChapterService` (sealed key `spheres_chapters_v1`)
keeps, per occasion the person hosted, the card and every page as received, so it
survives leaving the sphere. The profile carries only the chapter's title, event, date and
the host's own text under a per-field audience (`ProfileField.chapters`); other people's
pages cross a sphere boundary only with their writers' yes (milestone 6).

**Thanks and approvals are direct envelopes.** `thanks` (occasion id, text) to each named
person; `occasion_draft` to a child and `occasion_approval` back, before a child's moment
is posted. Both are small sealed messages like `chat_settings`, shown as a line in the chat.

### Milestones

| # | Milestone | Size | What lands | Exit criterion |
|---|---|---|---|---|
| C1 | **Occasion, page, moment, chapter** | 3 | `models/occasion.dart`; the `occasion` post kind in the composer with a plain card for every event (fields as faint prompts); `occasion_page` sent and received with the one-per-member rule; the clock (`isOpen`, the sweep, the host's one notification); the opening view: the card, then every page in the order received; `ChapterService` keeping the host's copy; the chapter list on the profile with audience. Pages are lines and postcards only. | Two phones: one hosts an award with a card and an hour; the other writes a postcard; nothing shows on either until the hour; at the hour both see the card and the postcard, the host is notified once, and the chapter is on the host's profile. Tests: parser (and the fuzz entry), one-per-member, late page, the clock, the chapter. |
| C2 | **The table and the reading** | 3 | The birthday table (pages laid around a circle, a `CustomPainter`, one place each); voice pages as audio blobs (the voice-note path, `blob_service`); the award's reading, by the host or by a colleague who asked (`reading` page); "I was there when" as the award's page kind; the degree's gown collage from pages with media (`MediaService.composeCollage`). | A birthday opens as a table on three phones with a photo, a line and a voice on it; an award opens with a colleague's reading playing. Tests: the table's placement is pure and tested; a reading page with audio round-trips; a collage from three pages. |
| C3 | **Thanks outward, the child as host, private pages** | 2 | `thanks` envelopes with "you were thanked" in the chat; `occasion_draft` and `occasion_approval` so a child's moment is posted only as the child approved it, with no trace of a refusal; private pages to the host; the candle. | A parent drafts a child's moment, the child changes the headline on their phone, and the sphere sees only the child's words; a private postcard reaches the host and nobody else. Tests: the approval rule, the privacy of a private page (never sealed to the sphere), the candle's invisibility. |
| C4 | **The professional set** | 4 | The new role's two lists and first-day opening (`opensAt` = first day); the project's plate with equal panels, the launch log as a media strip, and the register (pages from users); the founding letter and seeds (private pages with accept/decline as direct messages); the desk (object pages in a grid); the key and "what we keep". The case card with a signed attestation (a `word_for` envelope that names the card's version). | Each of the six opens on two phones with its own look; a seed is accepted and the founder alone sees it. Tests: the plate's equal panels, the register closing at a week, the attestation naming a version. |
| C5 | **The route, two chairs, the welcome book, pins, the kettle** | 4 | Point pages placed along a drawn route (the image editor's drawing tool for the route, pins as `point` pages); two chairs (two hosts, pages addressed to one or the other); the welcome book with an `opensAt` years away held by `ChapterService` and surfaced by the memories sweep; place pages as a list; the rota (`slot` pages, first signer by timestamp takes a slot, seen by the helped and the helpers only). | A marathon route opens with people placed along it; a rota fills on three phones without two people on one slot. Tests: slot conflict resolution by signed timestamp, the years-away opening, the two-chairs addressing. |
| C6 | **The wall, the export, anniversaries, the reminder line** | 2 | The wall (chapters of professional events, per sphere, on the profile); chapters shown to other spheres with the writers' consent (`page_consent` envelope); export of a chapter as an image or PDF by hand; the anniversary offer and the author-written caption through memories; the reminder line in the appreciation delivery for declared occasions. | A chapter exported to a PDF names only writers who said yes; an anniversary is offered once and never pushed. Tests: consent gating of pages crossing a sphere, the reminder uses declared occasions only. |

### Rules that every milestone keeps, and how a test sees them

- **Names, never counts.** No view ever renders a number of pages; the test for each
  opening view asserts the absence of a count widget.
- **Nothing before the hour.** `isOpen` gates every page in every view; a test sets the
  clock a minute before and asserts the card alone.
- **One page per member.** The receive rule replaces, never appends; a test sends two
  from one signer and finds one.
- **Private means the sphere never had it.** A test asserts a private page is sealed with
  `sealForDevices` to the host and never passed to `_publishToSphere`.
- **Silence is not shown.** No "has not written yet" anywhere; no member list on an
  occasion; a test asserts the opening view lists only writers.
- **The writing guide for every page.** The page composer opens through
  `showWritingGuide` with the event's questions; a test asserts the questions for every
  page kind exist and none is a sentence.
- **Occasions are declared.** Nothing in the code reads a date field to make one; the
  reminder (C6) reads only occasions and birthdays the person entered.

### What is reused, not written

The signed post core and its fuzz test; the feed's receive switch and attribution by
signer; the sync archive (`archiveEnvelope`) so a late member gets the pages; the daily
delivery hour (`AppreciationService`) for the host's notification and the reminder line;
the voice-note recorder and `blob_service` for audio and media pages; the collage; the
image editor's drawing for the route; `media_lock`'s sealed box for the child's draft;
`ProfileSharing` for the chapter's audience; the writing guide for every page.

### Not in this plan, by decision

Templates of any kind; a count anywhere; a "celebrate" reaction; prompting anyone to
write; computing an occasion from a date; pages crossing a sphere without the writer's
yes; sound that is not a person's voice; exporting with a link back.

## How this plan was made

Drafted here on 25 October 2026 against §12.6, then widened by a pass through OpenAI's
Codex (`codex exec`, read-only, given a self-contained brief with the rule and the
building blocks and no files from this repository). Codex returned sixteen ideas and
three rejections; the first page, the last question, the maker's plate, the unseen scene,
the founding letter, the field note, the witness postcard, the closed book with a
guaranteed keepsake, the practical gift, the equal panels, the child's chosen headline,
the kitchen-table interview, the case card with attestation, the letter across time, the
author-written caption and the drawer come from that pass and were kept because each
names the forbidden mechanic it avoids. Its three rejections matched the ones above.

Each step has tests on the models and the delivery rule, and the second rule of
`CLAUDE.md` applies to steps 2 and 4: they touch the message path.
