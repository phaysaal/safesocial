#!/bin/sh
# Prove the edge box from the outside: STUN answers on UDP and TCP, TLS on
# 5349 presents a valid certificate, ntfy is healthy over HTTPS and refuses
# anonymous publishes outside UnifiedPush topics.
#
#   ./check.sh turn.spheres.dev ntfy.spheres.dev
set -u
TURN_HOST="${1:?turn host}"; NTFY_HOST="${2:?ntfy host}"
fail=0

python3 - "$TURN_HOST" <<'PY' || fail=1
import socket, os, struct, sys
host = sys.argv[1]
req = struct.pack('!HHI', 0x0001, 0, 0x2112A442) + os.urandom(12)   # STUN binding request
ok = True
for proto, kind in (('udp', socket.SOCK_DGRAM), ('tcp', socket.SOCK_STREAM)):
    s = socket.socket(socket.AF_INET, kind); s.settimeout(5)
    try:
        s.connect((host, 3478)); s.send(req); data = s.recv(256)
        t = struct.unpack('!H', data[:2])[0]
        print(f"stun {proto}: {'ok' if t == 0x0101 else 'unexpected reply'}")
        ok &= t == 0x0101
    except Exception as e:
        print(f"stun {proto}: FAIL ({e})"); ok = False
    finally:
        s.close()
sys.exit(0 if ok else 1)
PY

if echo | openssl s_client -connect "$TURN_HOST:5349" -servername "$TURN_HOST" 2>/dev/null | grep -q "Verify return code: 0"; then
  echo "turns tls: ok"
else
  echo "turns tls: FAIL"; fail=1
fi

code=$(curl -s -o /dev/null -w '%{http_code}' "https://$NTFY_HOST/v1/health")
[ "$code" = 200 ] && echo "ntfy health: ok" || { echo "ntfy health: FAIL ($code)"; fail=1; }
code=$(curl -s -o /dev/null -w '%{http_code}' -d x "https://$NTFY_HOST/not-a-push-topic")
[ "$code" = 403 ] && echo "ntfy refuses other topics: ok" || { echo "ntfy refuses other topics: FAIL ($code)"; fail=1; }

exit $fail
