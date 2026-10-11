# Edge box: TURN and wakes

Everything Spheres needs outside Cloudflare runs on one small VM in the EU:

| Service | Why | Port |
|---|---|---|
| **coturn** | STUN and TURN for calls. A phone that cannot reach the other directly sends its encrypted media through here. The relay mints two-hour credentials from a shared secret (`relay/worker.js`, `handleTurn`), so no password lives on a phone. | UDP/TCP 3478, TLS 5349, relay ports UDP 49152–65535 |
| **ntfy** | UnifiedPush server for Android wakes. The relay posts an empty knock to a phone's topic when mail arrives and nobody is listening; the phone's ntfy app wakes Spheres. Anonymous access is limited to `up*` topics. | behind Caddy on 443 |
| **Caddy** | TLS for both names. It renews the certificates; a daily job copies the TURN one to coturn and reloads it. | 80, 443 |

As of 11 October 2026 this is the Scaleway Stardust1-S instance `safeself-web` in
Amsterdam, 51.158.179.30, Ubuntu, 1 GB of memory, which also serves safeself.fr. Both
services together use a few tens of MB; TURN costs bandwidth only while a relayed call
is up (about 15 KB/s each way for audio).

## Rebuild from scratch

1. A Debian or Ubuntu VM with a **public IPv4** and these inbound ports open at the
   provider: 22, 80, 443, 3478 tcp+udp, 5349 tcp, 49152–65535 udp.
2. Install Caddy (the distribution package is fine) so it owns 80/443.
3. DNS A records, not proxied: `turn.<domain>` and `ntfy.<domain>` → the IP.
4. Copy this directory to the box and run, as root:
   ```sh
   PUBLIC_IP=51.158.179.30 TURN_HOST=turn.spheres.dev NTFY_HOST=ntfy.spheres.dev ./setup.sh
   ```
   It installs coturn from apt and ntfy from the pinned GitHub release (checksum
   checked), writes the configs from the templates here, appends the two Caddy site
   blocks, opens ufw, waits for the TURN certificate and starts everything. Re-running
   is safe.
5. Put the secret on the relay, from `relay/`:
   ```sh
   printf '%s' "$(ssh root@<ip> "sed -n 's/^static-auth-secret=//p' /etc/turnserver.conf")" | npx wrangler secret put TURN_SECRET
   printf '%s' 'turn:turn.spheres.dev:3478?transport=udp,turn:turn.spheres.dev:3478?transport=tcp,turns:turn.spheres.dev:5349?transport=tcp' | npx wrangler secret put TURN_URLS
   ```
6. From anywhere: `./check.sh turn.spheres.dev ntfy.spheres.dev`.

## Proving it end to end

- **TURN:** on two devices, Settings → Call Servers → "Relay every call through TURN",
  then call. The log line `ICE: … TURN available, relay only` on the caller and a
  connected call mean the media went through coturn; `cat /proc/net/dev` on the box
  shows the traffic. Switch the setting off afterwards.
- **Wakes:** on the phone, the ntfy app's default server must be `https://ntfy.<domain>`
  (Settings → Default server), then restart Spheres so it re-registers its mailboxes
  (`Relay will knock on UnifiedPush for a mailbox (N registered)` in the log). Stop the
  app (`adb shell am stop-app com.spheres.spheres_app`), send it a message, and it
  comes back with `Woken for mail; syncing` within seconds.

## Files

| Path | Installed as |
|---|---|
| `coturn/turnserver.conf` | `/etc/turnserver.conf` (secret, IP and realm filled in) |
| `coturn/coturn-cert-sync` | `/usr/local/sbin/coturn-cert-sync`, run daily from `/etc/cron.d/coturn-cert-sync` |
| `ntfy/server.yml` | `/etc/ntfy/server.yml` |
| `caddy/spheres.caddy` | appended once to `/etc/caddy/Caddyfile` |

coturn never relays into private address ranges, has no CLI, logs to syslog without
session detail, and caps sessions per user and in total; the limits in the config suit a
1 GB box. ntfy keeps a twelve-hour message cache so a phone that was offline still gets
its knock, serves no web UI, and accepts no sign-ups.

## Not here

iOS wakes need an APNs key on the relay (`APNS_*` in `relay/wrangler.toml`), which is an
Apple developer account matter, not a server.
