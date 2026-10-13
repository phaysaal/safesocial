#!/usr/bin/env node
// Make a VAPID key pair (RFC 8292) for the relay's push knocks.
//
//   node scripts/vapid_keygen.mjs
//
// Prints the two values to set as Worker secrets:
//
//   npx wrangler secret put VAPID_PRIVATE_KEY   # paste the PEM block
//   npx wrangler secret put VAPID_PUBLIC_KEY    # paste the one-line key
//
// The public key is what every client fetches from `GET /` and hands its push
// distributor, so changing it means every device re-registers at its next
// start (which it does anyway). Keep the private key out of the repository.
import { webcrypto } from "node:crypto";

const crypto = webcrypto;
const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
const raw = Buffer.from(await crypto.subtle.exportKey("raw", pair.publicKey));
const publicKey = raw.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

const pem = ["-----BEGIN PRIVATE KEY-----", ...pkcs8.match(/.{1,64}/g), "-----END PRIVATE KEY-----"].join("\n");
console.log("VAPID_PRIVATE_KEY:\n" + pem + "\n");
console.log("VAPID_PUBLIC_KEY:\n" + publicKey);
