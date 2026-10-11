// Run after a deploy: `npm run smoke` (or `node test/smoke.mjs <host>`).
// Exercises the live relay with throwaway keys and leaves nothing behind but
// one empty mailbox object that expires with the retention sweep.
// Live smoke test of the v3 hub against the deployed relay.
const HOST = process.argv[2] || "relay.spheres.dev";
const b64url = (b) => Buffer.from(b).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const hex = (b) => Buffer.from(b).toString("hex");

const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const address = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey)));
const sign = async (m) => hex(new Uint8Array(await crypto.subtle.sign("Ed25519", kp.privateKey, new TextEncoder().encode(m))));
const hubId = b64url(crypto.getRandomValues(new Uint8Array(32)));

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const fail = (m) => { console.error("FAIL:", m); process.exit(1); };

// Two hubs: A publishes, B should receive live.
function open(id) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(`wss://${HOST}/hub/${id}`);
    ws.onopen = () => res(ws);
    ws.onerror = (e) => rej(new Error("ws error " + (e.message || "")));
  });
}
const waitFor = (ws, pred, ms = 8000) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error("timeout waiting for frame")), ms);
  const h = (ev) => { const f = JSON.parse(ev.data); if (pred(f)) { clearTimeout(t); ws.removeEventListener("message", h); res(f); } };
  ws.addEventListener("message", h);
});

const a = await open(hubId);
const b = await open(b64url(crypto.getRandomValues(new Uint8Array(32))));
log("hubs connected");

for (const ws of [a, b]) {
  const ts = String(Date.now());
  ws.send(JSON.stringify({ t: "sub", a: address, ts, sig: await sign(`SUB${address}${ts}`) }));
  const ok = await waitFor(ws, (f) => f.a === address && (f.t === "ok" || f.t === "err"));
  if (ok.t !== "ok") fail("subscribe refused: " + JSON.stringify(ok));
}
log("both hubs subscribed");

// A bad signature must be refused.
{
  const ts = String(Date.now());
  const bogus = b64url(crypto.getRandomValues(new Uint8Array(32)));
  a.send(JSON.stringify({ t: "sub", a: bogus, ts, sig: await sign(`SUB${bogus}${ts}`) }));
  const r = await waitFor(a, (f) => f.a === bogus);
  if (r.t !== "err" || r.e !== "unauthorized") fail("bogus subscribe not refused: " + JSON.stringify(r));
  log("wrong-key subscribe refused");
}

const payload = "5:hello";
const got = waitFor(b, (f) => f.t === "msg" && f.a === address);
a.send(JSON.stringify({ t: "pub", a: address, d: payload, id: 1 }));
const sent = await waitFor(a, (f) => f.t === "sent" || f.t === "err");
if (sent.t !== "sent") fail("publish failed: " + JSON.stringify(sent));
const msg = await got;
if (msg.d !== payload) fail("wrong payload delivered");
log("live delivery A -> B ok");

// Queued copy via HTTP sync, then ack.
const ts2 = String(Date.now());
const sync = await fetch(`https://${HOST}/mbx/${address}/sync`, { headers: { "X-Spheres-Signature": await sign(`GET/mbx/${address}/sync${ts2}`), "X-Spheres-Timestamp": ts2 } });
const pending = await sync.json();
if (!Array.isArray(pending) || pending.length !== 1 || pending[0].data !== payload) fail("sync did not return the queued copy: " + JSON.stringify(pending));
const body = JSON.stringify({ ids: pending.map((m) => m.id) });
const ts3 = String(Date.now());
const ack = await fetch(`https://${HOST}/mbx/${address}/ack`, { method: "POST", body, headers: { "Content-Type": "application/json", "X-Spheres-Signature": await sign(`POST/mbx/${address}/ack${body}${ts3}`), "X-Spheres-Timestamp": ts3 } });
if (ack.status !== 200) fail("ack failed " + ack.status);
log("queued copy fetched and acked");

// Cross-relay post, signed.
const ts4 = String(Date.now());
const postedFrame = waitFor(b, (f) => f.t === "msg" && f.d === "6:posted");
const post = await fetch(`https://${HOST}/mbx/${address}/post`, { method: "POST", body: "6:posted", headers: { "X-Spheres-Signature": await sign(`POST/mbx/${address}/post6:posted${ts4}`), "X-Spheres-Timestamp": ts4 } });
if (post.status !== 200) fail("signed post failed " + post.status);
const posted = await postedFrame;
log("signed /post reached the hub subscriber", posted.t);

// TURN should be honestly unconfigured.
const ts5 = String(Date.now());
const turn = await fetch(`https://${HOST}/turn/${address}`, { headers: { "X-Spheres-Signature": await sign(`GET/turn/${address}${ts5}`), "X-Spheres-Timestamp": ts5 } });
log("turn ->", turn.status, await turn.text());

// Ping/pong and unsubscribe.
a.send(JSON.stringify({ t: "ping" }));
await waitFor(a, (f) => f.t === "pong");
a.send(JSON.stringify({ t: "unsub", a: address }));
await waitFor(a, (f) => f.t === "ok" && f.a === address);
log("ping/pong and unsubscribe ok");

a.close(); b.close();
console.log("SMOKE OK");
process.exit(0);
