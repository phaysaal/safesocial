# Ideas to do, in order

Backlog of features agreed on 12 October 2026. `CLAUDE.md` describes what is built;
an item moves to "Done" here when it lands and its follow-ups stay in the list.

## Done

- **Protected photos and videos** (12 October 2026): see `CLAUDE.md`, "Protected media".
  Ran on the Motorola the same evening (two-finger hold, watermark, secure window, empty cache; the random-tile dance was replaced by a CRT-style scan after the first look). Follow-ups still open: tell the sender when iOS reports a screenshot (today the
  picture only hides and the viewer says so); the iOS secure-field blanking trick,
  which needs a Mac to build and prove; a hardware pass of the two-finger hold on the
  Motorola and the tablet.

## To do

1. **Consent-locked photos of people.** A picture that tags someone travels with its
   media key sealed only to the tagged people; others see a blurred frame and
   "waiting for Al" until each tagged person's device releases the key to the sphere.

2. **Quorum posts.** A post sealed under a key split with Shamir (`lib/crypto/`) among
   named members; opens when enough of them agree, or on a date their devices honour.

3. **Mutual-reveal profile fields.** A field shown only when both people have filled
   it in; a hash-commitment exchange in two envelopes, neither side learns the other's
   answer otherwise.

4. **Witnessed captures.** A nearby member's phone scans a short code within a minute
   of a capture and signs "I saw this taken here, now"; the signature travels as a
   provenance code and the origin score shows "witnessed by Al". Metadata only.

5. **Provably a member, provably nobody in particular.** An anonymous post with a
   linkable ring signature over the sphere's membership: provably by a member, provably
   not twice, unlinkable to anyone, admin included. The hardest item.

6. **Hold until they are back.** When a contact is on a break, a message waits on the
   sender's phone and shows "goes Monday"; the receiver's device never stores it.
