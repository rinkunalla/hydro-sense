// Phase 2 acceptance tests against the Auth, Firestore and Functions emulators.
// Run with `npm run test:emulator` from the repo root. Time-based rules are tested
// by back-dating stored timestamps, since the server clock cannot be fast-forwarded.
import { readFileSync } from "node:fs";
import { getAuth } from "firebase-admin/auth";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/https";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { addAllowedDevice, removeDevice, restoreDevice } from "../src/admin/devices";
import { setOwner } from "../src/admin/ownership";
import { C, db } from "../src/lib/db";
import { flipOfflineIfStale, runMonitorPass } from "../src/monitor/monitorDevices";

const PROJECT = process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836";
const FN = `http://127.0.0.1:5001/${PROJECT}/asia-east1`;
const FIRESTORE = process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080";
const AUTH = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099";
const KEY = /^PROVISIONING_KEY=(.+)$/m.exec(readFileSync(".secret.local", "utf8"))?.[1]?.trim();

const ID = "A1B2C3D4E5F6";
const ID2 = "A1B2C3D4E5F7";
const S = 1000;

type Json = Record<string, unknown>;

async function post(fn: string, body: unknown, headers: Record<string, string> = {}) {
  const res = await fetch(`${FN}/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as Json };
}

const register = (deviceId = ID, key = KEY ?? "") =>
  post("registerDevice", { deviceId, firmware: "1.0.0" }, { "X-Provisioning-Key": key });

const reading = (over: Json = {}): Json => ({
  flowStatus: "Normal Flow",
  flowRate: 10,
  pulseHz: 75, // still sent by firmware 0.2.0; ignored by the server (D29)
  batteryVoltage: 7.9,
  batteryFault: false,
  gpsValid: true,
  lat: 16.04,
  lng: 120.33,
  rssi: -60,
  firmware: "1.0.0",
  resetReason: null,
  trigger: "heartbeat",
  ...over,
});

const ingest = (token: string, over: Json = {}, deviceId = ID) =>
  post("deviceIngest", reading(over), {
    "X-Device-Id": deviceId,
    Authorization: `Bearer ${token}`,
  });

const dev = (id = ID) => db.collection(C.devices).doc(id);
const health = (id = ID) => db.collection(C.deviceHealth).doc(id);
const get = async (ref: FirebaseFirestore.DocumentReference) => (await ref.get()).data() ?? {};
const count = async (q: FirebaseFirestore.Query) => (await q.count().get()).data().count;
const ago = (seconds: number) => Timestamp.fromMillis(Date.now() - seconds * S);

async function allow(id = ID) {
  await db.collection(C.allowedDevices).doc(id).set({ addedAt: Timestamp.now() });
}

async function registered(id = ID): Promise<string> {
  await allow(id);
  const r = await register(id);
  expect(r.status).toBe(200);
  return r.body.token as string;
}

beforeAll(() => {
  if (!KEY) throw new Error("functions/.secret.local must define PROVISIONING_KEY");
});

beforeEach(async () => {
  await fetch(`http://${FIRESTORE}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {
    method: "DELETE",
  });
  // Admin callables need a live admin record, not only the claim.
  await db.collection(C.admins).doc("admin1").set({ name: "A", status: "active" });
});

describe("registerDevice", () => {
  it("rejects a bad key and a bad body with the standard shape", async () => {
    const bad = await register(ID, "wrong");
    expect(bad.status).toBe(401);
    expect(bad.body).toMatchObject({ ok: false, code: "PROVISIONING_KEY_INVALID" });
    expect(typeof bad.body.message).toBe("string");

    const body = await post("registerDevice", { deviceId: "nope" }, { "X-Provisioning-Key": KEY! });
    expect(body.status).toBe(400);
    expect(body.body.code).toBe("PAYLOAD_INVALID");
  });

  it("refuses an ID that is not allowlisted (403)", async () => {
    const r = await register();
    expect(r.status).toBe(403);
    expect(r.body.code).toBe("DEVICE_NOT_ALLOWED");
  });

  it("creates the device with ownerUid null, default nickname and starter cutoffs", async () => {
    await allow();
    const r = await register();
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ ok: true, lowFlowCutoff: 0.2, normalFlowCutoff: 2.0 });
    expect(await get(dev())).toMatchObject({
      ownerUid: null,
      nickname: "Device E5F6",
    });
    expect(await get(dev())).not.toHaveProperty("pausedUntil");
    expect(await get(health())).toMatchObject({ ownerUid: null, online: false, firmware: "1.0.0" });
    expect((await get(db.collection(C.deviceSecrets).doc(ID))).tokenHash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("keeps the owner and nickname of a device assigned before it registered (D41)", async () => {
    await allow();
    await setOwner(ID, "userA");
    expect(await get(health())).toMatchObject({ ownerUid: "userA", registeredAt: null });
    await dev().update({ nickname: "Garden Line" });
    expect((await register()).status).toBe(200);
    expect(await get(dev())).toMatchObject({ ownerUid: "userA", nickname: "Garden Line" });
    const h = await get(health());
    expect(h.ownerUid).toBe("userA");
    expect(h.registeredAt).not.toBeNull();
  });

  it("refuses re-registration while online (409); allows it offline with a new token", async () => {
    const first = await registered();
    expect((await ingest(first)).status).toBe(200);

    const active = await register();
    expect(active.status).toBe(409);
    expect(active.body.code).toBe("DEVICE_ACTIVE");

    await health().update({ online: false });
    const again = await register();
    expect(again.status).toBe(200);
    expect(again.body.token).not.toBe(first);
    expect((await ingest(first)).status).toBe(401);
    expect((await ingest(again.body.token as string)).status).toBe(200);
  });

  it("rate-limits registrations (429)", async () => {
    await allow();
    const hour = Math.floor(Date.now() / 3_600_000);
    await db.collection(C.rateLimits).doc(`register__${hour}`).set({ count: 20 });
    const r = await register();
    expect(r.status).toBe(429);
    expect(r.body.code).toBe("REGISTER_RATE_LIMITED");
  });
});

describe("deviceIngest", () => {
  it("rejects a bad token (401) and a bad payload (400)", async () => {
    const token = await registered();
    const auth = await ingest("not-the-token");
    expect(auth.status).toBe(401);
    expect(auth.body.code).toBe("DEVICE_AUTH_FAILED");

    const bad = await ingest(token, { flowRate: -3 });
    expect(bad.status).toBe(400);
    expect(bad.body).toMatchObject({ ok: false, code: "PAYLOAD_INVALID" });
  });

  it("applies a status change immediately and returns the cutoffs", async () => {
    const token = await registered();
    const r = await ingest(token, { trigger: "status_change" });
    expect(r.body).toEqual({ ok: true, lowFlowCutoff: 0.2, normalFlowCutoff: 2.0 });

    const d = await get(dev());
    expect(d).toMatchObject({ flowStatus: "Normal Flow", flowRate: 10, gpsLat: 16.04 });
    expect(d.statusChangedAt).toBeInstanceOf(Timestamp);
    const h = await get(health());
    expect(h).toMatchObject({ online: true, batteryVoltage: 7.9, batteryPercent: 72 });
    expect(h.lastSeen).toBeInstanceOf(Timestamp);
    expect(await count(dev().collection(C.flowLogs))).toBe(1);
  });

  it("writes only device_health for a steady heartbeat", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    const before = await get(dev());
    const r = await ingest(token, { flowRate: 10.5 });
    expect(r.status).toBe(200);
    expect((await get(dev())).updatedAt).toEqual(before.updatedAt);
    expect((await get(dev())).flowRate).toBe(10);
    expect(await count(dev().collection(C.flowLogs))).toBe(1);
    expect((await get(health())).recentVoltages).toHaveLength(2);
  });

  it("writes a 20 % rate change, but not more often than every 30 s", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    await ingest(token, { flowRate: 12, trigger: "rate_change" });
    expect((await get(dev())).flowRate).toBe(10);

    await dev().update({ updatedAt: ago(31) });
    await ingest(token, { flowRate: 12, trigger: "rate_change" });
    expect((await get(dev())).flowRate).toBe(12);
  });

  it("ignores a 20 % change below the 0.3 L/min floor", async () => {
    const token = await registered();
    await ingest(token, { flowStatus: "Low Flow", flowRate: 0.5, trigger: "status_change" });
    await dev().update({ updatedAt: ago(31) });
    await ingest(token, { flowStatus: "Low Flow", flowRate: 0.6 });
    expect((await get(dev())).flowRate).toBe(0.5);
  });

  it("refreshes devices.updatedAt at least every 5 min", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    await dev().update({ updatedAt: ago(301) });
    await ingest(token);
    const age = Date.now() - ((await get(dev())).updatedAt as Timestamp).toMillis();
    expect(age).toBeLessThan(10 * S);
  });

  it("samples flow_logs once per 5 min plus every status change", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    await ingest(token);
    expect(await count(dev().collection(C.flowLogs))).toBe(1);

    await health().update({ lastFlowLogAt: ago(301) });
    await ingest(token);
    expect(await count(dev().collection(C.flowLogs))).toBe(2);

    await ingest(token, { flowStatus: "Low Flow", flowRate: 1, trigger: "status_change" });
    const logs = await dev().collection(C.flowLogs).where("trigger", "==", "status_change").get();
    expect(logs.size).toBe(2);
  });

  it("keeps abnormalSince through Normal -> Low -> No and clears it on Normal", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    expect((await get(dev())).abnormalSince).toBeNull();

    await ingest(token, { flowStatus: "Low Flow", flowRate: 1, trigger: "status_change" });
    const since = (await get(dev())).abnormalSince as Timestamp;
    expect(since).toBeInstanceOf(Timestamp);

    await ingest(token, { flowStatus: "No Flow", flowRate: 0, trigger: "status_change" });
    expect(((await get(dev())).abnormalSince as Timestamp).toMillis()).toBe(since.toMillis());

    await ingest(token, { trigger: "status_change" });
    expect((await get(dev())).abnormalSince).toBeNull();
  });

  it("keeps the low-voltage sleep flag on device_health and writes no battery history", async () => {
    const token = await registered();
    await ingest(token, { batteryVoltage: 6.7, lowVoltageSleep: true });
    expect((await get(health())).lowVoltageSleep).toBe(true);
    await ingest(token);
    expect((await get(health())).lowVoltageSleep).toBe(false);
    expect(await count(health().collection("battery_logs"))).toBe(0);
    expect(await get(health())).not.toHaveProperty("lastBatteryLogAt");
  });

  it("accepts any pulseHz from old firmware, even a negative one (D29)", async () => {
    const token = await registered();
    expect((await ingest(token, { pulseHz: -5 })).status).toBe(200);
    expect((await ingest(token, { pulseHz: "fast" })).status).toBe(200);
  });

  it("logs repeated identical errors once per hour", async () => {
    const token = await registered();
    for (let i = 0; i < 3; i++) await ingest(token, { flowRate: "x" });
    const logs = await db.collection(C.errorLogs).where("code", "==", "PAYLOAD_INVALID").get();
    expect(logs.size).toBe(1);
    const entry = logs.docs[0]!.data();
    expect(entry).toMatchObject({ deviceId: ID, source: "deviceIngest" });
    expect(JSON.stringify(entry)).not.toMatch(/Garden|16\.04|120\.33/);
  });

  it("never touches alert collections", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    await ingest(token, { flowStatus: "No Flow", flowRate: 0, trigger: "status_change" });
    await ingest(token);
    expect(await count(db.collection("ai_insights"))).toBe(0);
    expect(await count(db.collection(C.alertState))).toBe(0);
    expect(await count(db.collection(C.alertDaily))).toBe(0);
  });
});

describe("monitorDevices", () => {
  it("flips a silent device offline after 3 min", async () => {
    const token = await registered();
    const token2 = await registered(ID2);
    await ingest(token);
    await ingest(token2, {}, ID2);

    await health().update({ lastSeen: ago(181) });
    const { flipped } = await runMonitorPass();
    expect(flipped).toEqual([ID]);
    expect((await get(health())).online).toBe(false);
    expect((await get(health(ID2))).online).toBe(true);
  });

  it("leaves a device online when an ingest lands before the flip transaction", async () => {
    const token = await registered();
    await ingest(token);
    await health().update({ lastSeen: ago(181) });
    await ingest(token); // lands between the candidate query and the transaction
    expect(await flipOfflineIfStale(ID, Date.now())).toBe(false);
    expect((await get(health())).online).toBe(true);
  });
});

describe("removeDevice", () => {
  const admin = <T>(data: T) =>
    ({ auth: { uid: "admin1", token: { role: "admin" } }, data }) as unknown as CallableRequest<T>;

  it("a removed device gets 403 and keeps its data; restoring lets it back in (D42)", async () => {
    await allow();
    const token = await registered();
    expect((await ingest(token)).status).toBe(200);
    await health().update({ online: false });

    await removeDevice.run(admin({ deviceId: ID.toLowerCase(), confirmLabel: ID }));
    expect((await get(dev())).removedAt).toBeTruthy();
    expect((await db.collection(C.allowedDevices).doc(ID).get()).exists).toBe(false);
    expect((await ingest(token)).status).toBe(401); // its token is gone
    const blocked = await register();
    expect(blocked.status).toBe(403);
    expect(blocked.body.code).toBe("DEVICE_NOT_ALLOWED");

    await restoreDevice.run(admin({ deviceId: ID }));
    expect(await get(dev())).not.toHaveProperty("removedAt");
    expect((await register()).status).toBe(200);
  });

  it("re-adding a removed ID restores it the same way", async () => {
    await allow();
    await registered();
    await removeDevice.run(admin({ deviceId: ID, confirmLabel: ID }));
    const r = await addAllowedDevice.run(admin({ deviceId: ID }));
    expect(r).toEqual({ deviceId: ID, restored: true });
    expect((await register()).status).toBe(200);
  });
});

describe("addAllowedDevice", () => {
  async function idToken(uid: string, role: string): Promise<string> {
    const auth = getAuth();
    const email = `${uid}@test.local`;
    await auth.deleteUser(uid).catch(() => undefined);
    await auth.createUser({ uid, email, password: "secret123" });
    await auth.setCustomUserClaims(uid, { role });
    const res = await fetch(
      `http://${AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, password: "secret123", returnSecureToken: true }),
      },
    );
    return ((await res.json()) as { idToken: string }).idToken;
  }

  const call = async (token: string, data: Json) => {
    const res = await fetch(`${FN}/addAllowedDevice`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ data }),
    });
    return (await res.json()) as { result?: Json; error?: { status: string; details?: Json } };
  };

  it("lets an admin add a normalized ID", async () => {
    const r = await call(await idToken("admin1", "admin"), { deviceId: "a1:b2:c3:d4:e5:f6" });
    expect(r.result).toEqual({ deviceId: ID, restored: false });
    expect((await db.collection(C.allowedDevices).doc(ID).get()).exists).toBe(true);
  });

  it("refuses a user and an invalid ID", async () => {
    const client = await call(await idToken("userA", "user"), { deviceId: ID });
    expect(client.error?.status).toBe("PERMISSION_DENIED");
    expect(client.error?.details?.code).toBe("NOT_ADMIN");

    const invalid = await call(await idToken("admin1", "admin"), { deviceId: "123" });
    expect(invalid.error?.status).toBe("INVALID_ARGUMENT");
    expect(invalid.error?.details?.code).toBe("DEVICE_ID_INVALID");
  });
});
