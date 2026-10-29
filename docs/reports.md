# Reports to the operator

"Report to Spheres" sends a report to the people who run Spheres, as Play's
user-generated-content and child-safety policies require of a social app.
Spheres is end-to-end encrypted, so a report can show what was said only
because the reporting user's phone, which holds it decrypted, includes it.

## How it travels

1. The phone fetches the operator's X25519 key from the relay (`GET /`, field
   `report`).
2. It builds the report (`models/abuse_report.dart`): reason, note, what is
   reported (post, message, comment, person or a general concern), the reported
   person's public key and the name the reporter knows them by, and, if the
   reporter chose, the words and up to three pictures as small JPEGs. Never the
   reporter's own identity.
3. It seals the report to that key (`SealedBox`, the same code that carries
   media keys to tagged people) and posts the box to `POST /report`.
4. The relay stores the box in chunks in one Durable Object, `reports_operator`,
   in the EU, and pings the operator's ntfy topic with a line that carries no
   content. It limits each client to 20 reports a day by a hash of its address
   and the day.

## Reading them

On the operator's computer, from `safesocial_app/`:

```bash
dart run tool/reports.dart list            # fetch, open, save to ~/.config/spheres/reports/<id>/
dart run tool/reports.dart delete <id>     # remove from the relay once dealt with
dart run tool/reports.dart ban <identity>  # the 64-hex "author" from a report
dart run tool/reports.dart unban <identity>
```

`~/.config/spheres/operator.json` (mode 600, never in the repository) holds the
private key, the operator token, the relay address and the ntfy topic. Losing
it means reports already stored can never be opened; a new `keygen` and new
secrets start over. The relay holds only the public key and the token, as the
Worker secrets `REPORT_PUBLIC_KEY`, `REPORT_ADMIN_TOKEN` and `REPORT_NTFY_URL`.

Subscribe to the ntfy topic in `operator.json` (field `ntfy`) in the ntfy app
to be told when a report arrives.

## What a ban does

`POST /moderation/ban/<address>` with the operator token marks the identity's
prekey room and inbox room: its bundle answers 410, it cannot republish it, and
its inbox refuses new contact requests. Nobody new can find or add it through
this relay. Conversations already set up run on pairwise mailboxes the relay
cannot link to anyone, and keep working; the terms say so.

## Child sexual abuse material

A report with reason `childSafety` is handled first. Confirmed material is
reported to the authorities as the law requires (NCMEC in the United States,
national law enforcement in the EU) and kept for them as long as the law
requires; everything else is deleted once dealt with.

## The contact address

`safety@spheres.dev` is the child safety and support contact on the terms and child
safety pages, and the one to give Play. It exists only as a Cloudflare Email Routing
rule (zone spheres.dev, enabled 29 October 2026) that forwards to the Cloudflare
account's own address; there is no mailbox at spheres.dev. The pages wrap it in
`<!--email_off-->` so Cloudflare's address obfuscation leaves it readable without
JavaScript. Replies go out from the forwarding address, not from spheres.dev.
