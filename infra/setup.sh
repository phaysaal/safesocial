#!/bin/sh
# Spheres edge box: coturn (STUN/TURN for calls) and ntfy (UnifiedPush wakes)
# behind Caddy, on one small Debian/Ubuntu VM with a public IPv4.
#
# Run as root on the box, from a checkout or a copy of this directory:
#
#   PUBLIC_IP=51.158.179.30 TURN_HOST=turn.spheres.dev NTFY_HOST=ntfy.spheres.dev ./setup.sh
#
# Idempotent: re-running rewrites the configs and restarts what changed. The
# TURN secret is generated on first run and kept in /etc/turnserver.conf; the
# same value must be stored on the relay Worker as TURN_SECRET (see README).
#
# Expects Caddy already installed and serving on 80/443 (it holds the
# certificates), ufw present, and DNS for both hosts pointing at PUBLIC_IP.
set -eu

: "${PUBLIC_IP:?set PUBLIC_IP to the box's public IPv4}"
: "${TURN_HOST:?set TURN_HOST, e.g. turn.spheres.dev}"
: "${NTFY_HOST:?set NTFY_HOST, e.g. ntfy.spheres.dev}"
TURN_REALM="${TURN_REALM:-${TURN_HOST#*.}}"
NTFY_VERSION="${NTFY_VERSION:-2.29.0}"
NTFY_SHA256="${NTFY_SHA256:-e2e693d6490e5d33ef4310a48cbd36f2b1c67cb5fc5cbb6a55d1118836d453c5}"

here=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive

command -v caddy >/dev/null || { echo "Caddy is not installed; install it first (it owns 80/443 and the certificates)." >&2; exit 1; }

# ── Packages ─────────────────────────────────────────────────────────────────
apt-get install -y -q coturn >/dev/null
if ! dpkg -s ntfy 2>/dev/null | grep -q "^Version: $NTFY_VERSION"; then
  tmp=$(mktemp -d)
  curl -sSL -o "$tmp/ntfy.deb" "https://github.com/binwiederhier/ntfy/releases/download/v$NTFY_VERSION/ntfy_${NTFY_VERSION}_linux_amd64.deb"
  echo "$NTFY_SHA256  $tmp/ntfy.deb" | sha256sum -c - >/dev/null
  dpkg -i "$tmp/ntfy.deb" >/dev/null
  rm -rf "$tmp"
fi

# ── coturn ───────────────────────────────────────────────────────────────────
secret=$(sed -n 's/^static-auth-secret=//p' /etc/turnserver.conf 2>/dev/null | grep -v '^__' || true)
if [ -z "$secret" ]; then
  secret=$(openssl rand -hex 32)
  echo "New TURN secret generated. Store it on the relay: npx wrangler secret put TURN_SECRET"
fi
sed -e "s/__TURN_SECRET__/$secret/" -e "s/__PUBLIC_IP__/$PUBLIC_IP/g" -e "s/__TURN_REALM__/$TURN_REALM/" \
  "$here/coturn/turnserver.conf" > /etc/turnserver.conf
chmod 640 /etc/turnserver.conf; chown root:turnserver /etc/turnserver.conf
sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
sed "s/__TURN_HOST__/$TURN_HOST/g" "$here/coturn/coturn-cert-sync" > /usr/local/sbin/coturn-cert-sync
chmod 755 /usr/local/sbin/coturn-cert-sync
echo "17 4 * * * root /usr/local/sbin/coturn-cert-sync" > /etc/cron.d/coturn-cert-sync

# ── ntfy ─────────────────────────────────────────────────────────────────────
mkdir -p /etc/ntfy /var/cache/ntfy /var/lib/ntfy
sed "s/__NTFY_HOST__/$NTFY_HOST/" "$here/ntfy/server.yml" > /etc/ntfy/server.yml
chown -R ntfy:ntfy /var/cache/ntfy /var/lib/ntfy /etc/ntfy

# ── Caddy ────────────────────────────────────────────────────────────────────
if ! grep -q "^$NTFY_HOST" /etc/caddy/Caddyfile; then
  { echo; sed -e "s/__NTFY_HOST__/$NTFY_HOST/" -e "s/__TURN_HOST__/$TURN_HOST/" "$here/caddy/spheres.caddy"; } >> /etc/caddy/Caddyfile
fi
caddy validate --config /etc/caddy/Caddyfile >/dev/null
systemctl reload caddy

# ── Firewall ─────────────────────────────────────────────────────────────────
for rule in 80/tcp 443 3478/tcp 3478/udp 5349/tcp 49152:65535/udp; do ufw allow "$rule" >/dev/null; done

# ── Services ─────────────────────────────────────────────────────────────────
systemctl enable coturn ntfy >/dev/null 2>&1
systemctl restart ntfy
# The TLS listener needs the certificate, which Caddy fetches once DNS points
# here. Wait a little for it, then sync; coturn starts without TLS if it is
# not there yet and picks it up on the next daily sync.
for _ in $(seq 1 24); do
  [ -f "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$TURN_HOST/$TURN_HOST.key" ] && break
  sleep 5
done
/usr/local/sbin/coturn-cert-sync || true
if [ ! -f /etc/coturn/certs/turn.key ]; then
  echo "No certificate for $TURN_HOST yet; starting coturn without TLS. Re-run or wait for the daily sync." >&2
  sed -i 's/^tls-listening-port=/#tls-listening-port=/; s/^cert=/#cert=/; s/^pkey=/#pkey=/' /etc/turnserver.conf
fi
systemctl restart coturn

echo "Done. Relay secrets to set (relay/):"
echo "  printf '%s' '<secret from /etc/turnserver.conf>' | npx wrangler secret put TURN_SECRET"
echo "  printf '%s' 'turn:$TURN_HOST:3478?transport=udp,turn:$TURN_HOST:3478?transport=tcp,turns:$TURN_HOST:5349?transport=tcp' | npx wrangler secret put TURN_URLS"
echo "Then ./check.sh $TURN_HOST $NTFY_HOST from anywhere."
