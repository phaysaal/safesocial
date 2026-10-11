// Tests for the relay worker, run with `node --test test/`.
//
// The worker is exercised in-process against a fake Durable Object runtime:
// a storage map, a socket list, and a namespace that routes stub fetches to
// the right object instance. Signatures are real Ed25519 over WebCrypto, so
// what is tested is the protocol, not a mock of it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";

import worker, { RelayRoom } from "../worker.js";

globalThis.crypto ??= webcrypto;

// ── Fake runtime ─────────────────────────────────────────────────────────────

class FakeStorage {
  constructor() {
    this.map = new Map();
    this.alarm = null;
  }
  async get(k) {
    return this.map.get(k);
  }
  async put(k, v) {
    this.map.set(k, v);
  }
  async delete(k) {
    this.map.delete(k);
  }
  async deleteAll() {
    this.map.clear();
  }
  async transaction(fn) {
    await fn(this);
  }
  async getAlarm() {
    return this.alarm;
  }
  async setAlarm(t) {
    this.alarm = t;
  }
}

class FakeSocket {
  constructor() {
    this.sent = [];
    this.attachment = null;
    this.closed = false;
  }
  send(m) {
    if (this.closed) throw new Error("closed");
    this.sent.push(m);
  }
  serializeAttachment(a) {
    this.attachment = a;
  }
  deserializeAttachment() {
    return this.attachment;
  }
}

class FakeState {
  constructor(name) {
    this.id = { name };
    this.storage = new FakeStorage();
    this.sockets = [];
    this.waited = [];
  }
  getWebSockets() {
    return this.sockets;
  }
  acceptWebSocket(ws) {
    this.sockets.push(ws);
  }
  waitUntil(p) {
    this.waited.push(p);
  }
}

function makeEnv(vars = {}) {
  const objects = new Map();
  const ns = {
    jurisdiction() {
      return ns;
    },
    idFromName(name) {
      return { name };
    },
    get(id) {
      if (!objects.has(id.name)) {
        objects.set(id.name, new RelayRoom(new FakeState(id.name), env));
      }
      const obj = objects.get(id.name);
      return {
        fetch(input, init) {
          const req = input instanceof Request ? input : new Request(input, init);
          return obj.fetch(req);
        },
      };
    },
  };
  const env = { RELAY_ROOM: ns, ...vars };
  env._objects = objects;
  return env;
}

// ── Keys ─────────────────────────────────────────────────────────────────────

function b64url(bytes) {
  return Buffer.from(bytes).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function hex(bytes) {
  return Buffer.from(bytes).toString("hex");
}

async function mailbox() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  const address = b64url(pub);
  async function sign(message) {
    const sig = await crypto.subtle.sign("Ed25519", kp.privateKey, new TextEncoder().encode(message));
    return hex(new Uint8Array(sig));
  }
  async function signedRequest(method, path, body = "") {
    const ts = String(Date.now());
    const sig = await sign(`${method}${path}${body}${ts}`);
    return new Request(`https://relay${path}`, {
      method,
      body: method === "GET" ? undefined : body,
      headers: { "X-Spheres-Signature": sig, "X-Spheres-Timestamp": ts },
    });
  }
  async function subFrame() {
    const ts = String(Date.now());
    return { t: "sub", a: address, ts, sig: await sign(`SUB${address}${ts}`) };
  }
  return { address, sign, signedRequest, subFrame };
}

const HUB_A = b64url(crypto.getRandomValues(new Uint8Array(32)));
const HUB_B = b64url(crypto.getRandomValues(new Uint8Array(32)));

function hubFor(env, id) {
  env.RELAY_ROOM.get({ name: `hub_${id}` }); // ensure instantiated
  return env._objects.get(`hub_${id}`);
}
function mailboxFor(env, address) {
  env.RELAY_ROOM.get({ name: `mbx_${address}` });
  return env._objects.get(`mbx_${address}`);
}

function attachHubSocket(hub, id) {
  const ws = new FakeSocket();
  ws.serializeAttachment({ kind: "hub", id });
  hub.state.acceptWebSocket(ws);
  return ws;
}

const last = (ws) => JSON.parse(ws.sent[ws.sent.length - 1]);

// ── Tests ────────────────────────────────────────────────────────────────────

test("root reports version and configuration flags", async () => {
  const env = makeEnv({ DO_JURISDICTION: "eu" });
  const res = await worker.fetch(new Request("https://relay/"), env);
  const body = await res.json();
  assert.equal(body.status, "blind");
  assert.equal(body.jurisdiction, "eu");
  assert.equal(body.turn, false);
  assert.equal(body.apns, false);
});

test("a hub subscription needs a signature from the mailbox key", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const hub = hubFor(env, HUB_A);
  const ws = attachHubSocket(hub, HUB_A);

  // Wrong signature: signed for a different address.
  const other = await mailbox();
  const bad = await other.subFrame();
  bad.a = mb.address;
  await hub.webSocketMessage(ws, JSON.stringify(bad));
  assert.deepEqual(last(ws), { t: "err", a: mb.address, e: "unauthorized" });

  // Right signature.
  await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));
  assert.deepEqual(last(ws), { t: "ok", a: mb.address });

  const subs = await mailboxFor(env, mb.address).state.storage.get("subs");
  assert.equal(subs.length, 1);
  assert.equal(subs[0].hub, `hub_${HUB_A}`);
});

test("a frame published on one hub reaches the other hub and is queued", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const hubA = hubFor(env, HUB_A);
  const hubB = hubFor(env, HUB_B);
  const wsA = attachHubSocket(hubA, HUB_A);
  const wsB = attachHubSocket(hubB, HUB_B);

  await hubA.webSocketMessage(wsA, JSON.stringify(await mb.subFrame()));
  await hubB.webSocketMessage(wsB, JSON.stringify(await mb.subFrame()));

  await hubA.webSocketMessage(wsA, JSON.stringify({ t: "pub", a: mb.address, d: "hello", id: 7 }));

  // Sender gets an ack for its id, not an echo of its own message.
  assert.deepEqual(last(wsA), { t: "sent", a: mb.address, id: 7 });
  assert.equal(wsA.sent.filter((m) => JSON.parse(m).t === "msg").length, 0);

  // Receiver gets the message.
  assert.deepEqual(last(wsB), { t: "msg", a: mb.address, d: "hello" });

  // And it is queued regardless, for the next sync.
  const res = await mailboxFor(env, mb.address).fetch(
    await mb.signedRequest("GET", `/mbx/${mb.address}/sync`),
  );
  const pending = await res.json();
  assert.equal(pending.length, 1);
  assert.equal(pending[0].data, "hello");
});

test("publishing without a subscription is refused", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const hub = hubFor(env, HUB_A);
  const ws = attachHubSocket(hub, HUB_A);

  await hub.webSocketMessage(ws, JSON.stringify({ t: "pub", a: mb.address, d: "x" }));
  assert.deepEqual(last(ws), { t: "err", a: mb.address, e: "unsubscribed" });

  const res = await mailboxFor(env, mb.address).fetch(
    await mb.signedRequest("GET", `/mbx/${mb.address}/sync`),
  );
  assert.deepEqual(await res.json(), []);
});

test("a guessed token cannot publish or deliver", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const hub = hubFor(env, HUB_A);
  const ws = attachHubSocket(hub, HUB_A);
  await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));

  const publish = await mailboxFor(env, mb.address).fetch(
    new Request(`https://relay/mbx/${mb.address}/publish`, {
      method: "POST",
      headers: { "X-Hub-Token": "not-a-token" },
      body: "x",
    }),
  );
  assert.equal(publish.status, 401);

  const deliver = await hub.fetch(
    new Request(`https://relay/hub/${HUB_A}/deliver`, {
      method: "POST",
      headers: { "X-Hub-Token": "not-a-token" },
      body: JSON.stringify({ a: mb.address, d: "injected" }),
    }),
  );
  assert.equal(deliver.status, 401);
  assert.equal(ws.sent.filter((m) => JSON.parse(m).t === "msg").length, 0);
});

test("a hub whose client left is dropped by the mailbox on next delivery", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const hubA = hubFor(env, HUB_A);
  const hubB = hubFor(env, HUB_B);
  const wsA = attachHubSocket(hubA, HUB_A);
  const wsB = attachHubSocket(hubB, HUB_B);
  await hubA.webSocketMessage(wsA, JSON.stringify(await mb.subFrame()));
  await hubB.webSocketMessage(wsB, JSON.stringify(await mb.subFrame()));

  // B's socket vanishes without an unsubscribe (app killed).
  hubB.state.sockets.length = 0;

  await hubA.webSocketMessage(wsA, JSON.stringify({ t: "pub", a: mb.address, d: "m1" }));
  const subs = await mailboxFor(env, mb.address).state.storage.get("subs");
  assert.deepEqual(subs.map((s) => s.hub), [`hub_${HUB_A}`]);
});

test("closing the hub socket releases its subscriptions", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const hub = hubFor(env, HUB_A);
  const ws = attachHubSocket(hub, HUB_A);
  await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));

  hub.state.sockets.length = 0;
  await hub.webSocketClose(ws);

  assert.equal(await hub.state.storage.get("hubSubs"), undefined);
  const subs = await mailboxFor(env, mb.address).state.storage.get("subs");
  assert.deepEqual(subs, []);
});

test("a wake is sent only when nobody was listening, and is coalesced", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const calls = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return new Response("", { status: 200 });
  };
  try {
    const box = mailboxFor(env, mb.address);
    const reg = await box.fetch(
      await mb.signedRequest(
        "POST",
        `/mbx/${mb.address}/wake`,
        JSON.stringify({ url: "https://ntfy.example/abc" }),
      ),
    );
    assert.equal(reg.status, 200);

    // Nobody listening: a wake goes out, with no content.
    await box.deliver("m1");
    await Promise.all(box.state.waited);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://ntfy.example/abc");
    assert.equal(calls[0].init.body, "");

    // Second message straight after: coalesced.
    await box.deliver("m2");
    await Promise.all(box.state.waited);
    assert.equal(calls.length, 1);

    // Someone listening: no wake.
    box.state.storage.map.delete("lastWake");
    const hub = hubFor(env, HUB_A);
    const ws = attachHubSocket(hub, HUB_A);
    await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));
    await box.deliver("m3");
    await Promise.all(box.state.waited);
    assert.equal(calls.length, 1);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("wake targets must be https, and APNs needs configuration", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const box = mailboxFor(env, mb.address);

  const http = await box.fetch(
    await mb.signedRequest("POST", `/mbx/${mb.address}/wake`, JSON.stringify({ url: "http://x/y" })),
  );
  assert.equal(http.status, 400);

  const apns = await box.fetch(
    await mb.signedRequest(
      "POST",
      `/mbx/${mb.address}/wake`,
      JSON.stringify({ url: `apns:${"ab".repeat(32)}` }),
    ),
  );
  assert.equal(apns.status, 501);

  const unsigned = await box.fetch(
    new Request(`https://relay/mbx/${mb.address}/wake`, {
      method: "POST",
      body: JSON.stringify({ url: "https://x/y" }),
    }),
  );
  assert.equal(unsigned.status, 401);
});

test("TURN credentials are refused until configured, then issued short-lived", async () => {
  const mb = await mailbox();
  const unconfigured = await worker.fetch(
    await mb.signedRequest("GET", `/turn/${mb.address}`),
    makeEnv(),
  );
  assert.equal(unconfigured.status, 501);

  const env = makeEnv({ TURN_SECRET: "s3cret", TURN_URLS: "turn:turn.example:3478, turns:turn.example:5349" });
  const anon = await worker.fetch(new Request(`https://relay/turn/${mb.address}`), env);
  assert.equal(anon.status, 401);

  const res = await worker.fetch(await mb.signedRequest("GET", `/turn/${mb.address}`), env);
  assert.equal(res.status, 200);
  const creds = await res.json();
  assert.deepEqual(creds.urls, ["turn:turn.example:3478", "turns:turn.example:5349"]);
  const [expiry, label] = creds.username.split(":");
  assert.ok(Number(expiry) > Date.now() / 1000);
  assert.ok(!creds.username.includes(mb.address), "address must not appear in the TURN username");
  assert.ok(label.length > 0);
  assert.ok(creds.credential.length > 0);
});

test("blob chunks are capped by count and by bytes", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const box = env.RELAY_ROOM.get({ name: `blob_${mb.address}` });

  const tooHigh = await box.fetch(await mb.signedRequest("PUT", `/blob/${mb.address}/1400`, "x"));
  assert.equal(tooHigh.status, 400);

  const ok = await box.fetch(await mb.signedRequest("PUT", `/blob/${mb.address}/1399`, "x"));
  assert.equal(ok.status, 200);

  const dup = await box.fetch(await mb.signedRequest("PUT", `/blob/${mb.address}/1399`, "x"));
  assert.equal(dup.status, 409);

  // Pretend the blob is already at the cap: the next chunk is refused.
  const obj = env._objects.get(`blob_${mb.address}`);
  await obj.state.storage.put("blobBytes", 64 * 1024 * 1024 * 2);
  const over = await box.fetch(await mb.signedRequest("PUT", `/blob/${mb.address}/2`, "x"));
  assert.equal(over.status, 413);
});

test("the worker routes four-digit chunk indices", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const res = await worker.fetch(
    new Request(`https://relay/blob/${mb.address}/1234`),
    env,
  );
  assert.equal(res.status, 404, "routed to the object, which has no such chunk");
  const five = await worker.fetch(new Request(`https://relay/blob/${mb.address}/12345`), env);
  assert.equal(five.status, 404);
  assert.equal(await five.text(), "Not found.");
});

test("a mailbox full of hubs that never closed gives the oldest slot to a newcomer", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const box = mailboxFor(env, mb.address);
  const dead = [];
  for (let i = 0; i < 16; i++) {
    const id = b64url(crypto.getRandomValues(new Uint8Array(32)));
    const hub = hubFor(env, id);
    const ws = attachHubSocket(hub, id);
    await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));
    assert.equal(last(ws).t, "ok");
    dead.push({ id, hub, ws });
  }
  assert.equal((await box.state.storage.get("subs")).length, 16);

  const hub = hubFor(env, HUB_B);
  const ws = attachHubSocket(hub, HUB_B);
  await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));
  assert.equal(last(ws).t, "ok", "the newcomer is admitted, not refused");

  const subs = await box.state.storage.get("subs");
  assert.equal(subs.length, 16, "the cap holds");
  assert.ok(subs.some((s) => s.hub === `hub_${HUB_B}`));
  assert.ok(!subs.some((s) => s.hub === `hub_${dead[0].id}`), "the oldest slot went");
  assert.ok(subs.some((s) => s.hub === `hub_${dead[1].id}`), "the second-oldest stayed");

  // The evicted hub finds out on its next publish and is told to re-prove.
  await dead[0].hub.webSocketMessage(
    dead[0].ws,
    JSON.stringify({ t: "pub", a: mb.address, d: "late", id: 7 }),
  );
  assert.equal(last(dead[0].ws).e, "unsubscribed");
});

test("a direct v2 socket frame still fans out to hub subscribers", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const box = mailboxFor(env, mb.address);
  const hub = hubFor(env, HUB_A);
  const ws = attachHubSocket(hub, HUB_A);
  await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));

  const direct = new FakeSocket();
  direct.serializeAttachment({ kind: "mbx" });
  box.state.acceptWebSocket(direct);
  await box.webSocketMessage(direct, "legacy");

  assert.deepEqual(last(ws), { t: "msg", a: mb.address, d: "legacy" });
  assert.equal(direct.sent.length, 0, "the sender does not get its own frame back");
});

test("a signed post from another relay is delivered and queued without a subscription", async () => {
  const env = makeEnv();
  const mb = await mailbox();
  const hub = hubFor(env, HUB_A);
  const ws = attachHubSocket(hub, HUB_A);
  await hub.webSocketMessage(ws, JSON.stringify(await mb.subFrame()));

  const box = mailboxFor(env, mb.address);
  const posted = await box.fetch(
    await mb.signedRequest("POST", `/mbx/${mb.address}/post`, "from-afar"),
  );
  assert.equal(posted.status, 200);
  assert.deepEqual(last(ws), { t: "msg", a: mb.address, d: "from-afar" });

  const unsigned = await box.fetch(
    new Request(`https://relay/mbx/${mb.address}/post`, { method: "POST", body: "x" }),
  );
  assert.equal(unsigned.status, 401);

  const res = await box.fetch(await mb.signedRequest("GET", `/mbx/${mb.address}/sync`));
  assert.equal((await res.json()).length, 1);
});
