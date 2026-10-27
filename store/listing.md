# Play listing for Spheres (draft, 27 October 2026)

Everything here is a draft to edit before pasting. Limits are Play's.

## App details

- **App name** (30): `Spheres`
- **Developer name shown**: `Counterself`
- **Category**: Social
- **Contact email**: *yours to fill*
- **Website**: `https://spheres.dev`
- **Privacy policy**: `https://spheres.dev/privacy`

## Short description (80)

```
A private social network for the people you know. Nothing public, nothing sold.
```

(79 characters)

## Full description (4000)

```
Spheres is a social network with no public audience. Everything you share goes
to a sphere: a named group of people you chose, like your family, your team, a
client group or old friends. Nobody else can see it, and that includes us.

PRE-ALPHA. This is an early test build. It works between phones and is used
every day by the people making it, but it has not been independently audited.
Do not rely on it where being read would put you at risk.

WHAT IT DOES
- Posts, photos, videos, comments and reactions, inside the spheres you choose
- Flashes: moments that last a day
- Chats with people and with whole spheres, voice notes, files, polls
- Voice and video calls, and the camera can come on or off mid-call
- Albums, events with RSVP, a calendar link, memories
- A look for every picture: colour and light you can change after posting,
  with the original always one hold away
- A built-in Self sphere for notes and things to keep
- Notes from your side of a call, made on your phone, if you turn them on

WHAT IT REFUSES
- No public profiles, no followers, no strangers in your feed
- No ranking algorithm: the feed is in time order and ends
- No like counts shown to everyone; appreciation arrives once a day, by name
- No analytics, no tracking, no advertising network
- Nothing about what you read or how long is ever recorded or sent

PRIVACY, IN PLAIN WORDS
Everything is end-to-end encrypted on your phone. The relay that carries it
cannot read it and cannot tell who is talking to whom. Your data is encrypted
on the phone too. Your identity is a key pair on your device; there is no
account on our side. Delete everything from Settings, and the relay is told to
drop what little it holds. The privacy page says exactly what the servers see:
https://spheres.dev/privacy

Open source: https://github.com/phaysaal/safesocial
```

## Release notes for the first closed-test release (500)

```
First closed test of the pre-alpha. Please try: making a sphere and inviting
someone, posting a photo with a look, a voice and video call (turn the camera
on and off), and the daily appreciation. Tell us what breaks.
```

## Graphics

| Asset | File | Status |
|---|---|---|
| App icon, 512×512 PNG | `store/icon_512.png` | made from the launcher icon |
| Feature graphic, 1024×500 | `store/feature_graphic_1024x500.png` | made from the logo and the app's palette |
| Phone screenshots, at least 2 | *to take* | from a phone with content you are happy to show |

Screenshots: Home with a few posts, a sphere's page, a chat, the look sheet over
a photo, the "You're caught up" end of the feed. Take them on a phone whose
spheres hold nothing private; the Samsung's are real.

## App content answers

| Form | Answer |
|---|---|
| Privacy policy | `https://spheres.dev/privacy` |
| App access | All functionality available without special access (anyone can create an identity) |
| Ads | No |
| Content rating | Social; users interact and share content; no violence, sexual content, gambling or drugs in the app itself |
| Target audience | 13 and over; not designed for children |
| News app | No |
| Government app | No |
| Financial features | None |
| Health | No |
| Data safety: collected | None by the developer in Play's sense. Messages, photos and other content are end-to-end encrypted and not readable by us |
| Data safety: shared | None |
| Data safety: encrypted in transit | Yes |
| Data safety: deletion | Yes, in the app (Settings, Reset Everything) and described at `https://spheres.dev/privacy` |
| Account creation | Yes, in the app; deletion in the app and at the privacy page |

Note on data safety: Play's definitions count data sent off the device. The relay
receives encrypted content and IP addresses in transit, which Play treats as
"not collected" when it is end-to-end encrypted and not stored for the
developer's use. If the form insists, declare "messages" as collected,
encrypted in transit, not shared, for app functionality, deletable.

## The bundle

```
safesocial_app/build/app/outputs/bundle/playRelease/app-play-release.aab
```

Version 0.11.0, version code 56. Each later upload needs a higher version code;
`./build_release.sh` raises it.
