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
import { C, db, liveRef, rtdb, stateRef } from "../src/lib/db";
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
const live = async (id = ID) => ((await liveRef(id).get()).val() ?? {}) as Json;
const state = async (id = ID) => ((await stateRef(id).get()).val() ?? {}) as Json;
const problems = (id = ID) => db.collection(C.problems).where("deviceId", "==", id);
const setLastSeen = (secondsAgo: number, id = ID) =>
  liveRef(id).update({ lastSeen: Date.now() - secondsAgo * S });

/** Waits for the devices trigger to mirror a change to /state (D48). */
async function mirrored(check: (st: Json) => boolean) {
  for (let i = 0; i < 50; i++) {
    if (check(await state())) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("the devices trigger did not mirror the change");
}

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
  await rtdb.ref().set(null);
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

    await liveRef(ID).update({ online: false });
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
  it("returns the owner's own Low flow limit while it is set (D43)", async () => {
    const token = await registered();
    await dev().update({ normalFlowCutoff: 4, lowFlowCutoff: 1.2 });
    await mirrored((st) => st.normalFlowCutoff === 4);
    expect((await ingest(token)).body).toMatchObject({ lowFlowCutoff: 1.2, normalFlowCutoff: 4 });
    await dev().update({ userNormalCutoff: 6.5 });
    await mirrored((st) => st.normalFlowCutoff === 6.5);
    expect((await ingest(token)).body).toMatchObject({ lowFlowCutoff: 0.2, normalFlowCutoff: 6.5 });
    await dev().update({ userNormalCutoff: null });
    await mirrored((st) => st.normalFlowCutoff === 4);
    expect((await ingest(token)).body).toMatchObject({ lowFlowCutoff: 1.2, normalFlowCutoff: 4 });
  });

  it("rejects a bad token (401) and a bad payload (400)", async () => {
    const token = await registered();
    const auth = await ingest("not-the-token");
    expect(auth.status).toBe(401);
    expect(auth.body.code).toBe("DEVICE_AUTH_FAILED");

    const bad = await ingest(token, { flowRate: -3 });
    expect(bad.status).toBe(400);
    expect(bad.body).toMatchObject({ ok: false, code: "PAYLOAD_INVALID" });
  });

  it("writes the live node and returns the cutoffs and pace", async () => {
    const token = await registered();
    const r = await ingest(token, { trigger: "status_change", heartbeatS: 30 });
    // The reply also sets the upload pace (D47); firmware 0.2.0 ignores it.
    expect(r.body).toEqual({
      ok: true,
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2.0,
      heartbeatS: 20,
      rateMinIntervalS: 5,
    });
    const l = await live();
    expect(l).toMatchObject({
      online: true,
      flowStatus: "Normal Flow",
      flowRate: 10,
      batteryPercent: 72,
      heartbeatS: 30,
    });
    expect(Math.abs(Date.now() - (l.lastSeen as number))).toBeLessThan(10 * S);
    expect(l).not.toHaveProperty("rssi"); // the owner sees no radio data
    expect((await state()).recentVoltages).toEqual([7.9]);
  });

  it("a steady heartbeat writes nothing to Firestore (D48)", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" }); // first sample of the day
    const before = await get(dev());
    const logs = await count(dev().collection(C.flowLogs));
    for (let i = 0; i < 3; i++) await ingest(token, { flowRate: 10 + i });
    expect(await get(dev())).toEqual(before);
    expect(await count(dev().collection(C.flowLogs))).toBe(logs);
    expect(await count(db.collection(C.problems))).toBe(0);
    expect((await live()).flowRate).toBe(12);
  });

  it("samples flow_logs once per 15 min, for calibration", async () => {
    const token = await registered();
    await ingest(token);
    await ingest(token);
    expect(await count(dev().collection(C.flowLogs))).toBe(1);
    await stateRef(ID).update({ lastSampleAt: Date.now() - 901 * S });
    await ingest(token);
    expect(await count(dev().collection(C.flowLogs))).toBe(2);
  });

  it("writes this minute's flow into today's live series (D60)", async () => {
    const token = await registered();
    await ingest(token, { flowRate: 19.6 });
    const days = ((await rtdb.ref(`series/${ID}`).get()).val() ?? {}) as Record<
      string,
      Record<string, number>
    >;
    const [day] = Object.keys(days);
    expect(day).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(Object.values(days[day!]!)).toEqual([19.6]);
    expect((await state()).seriesDay).toBe(day);
    // A drop later in the same minute keeps the minute's peak.
    await ingest(token, { flowRate: 0 });
    const minute = (await state()).seriesMinute!;
    if (minute.startsWith(day!)) {
      expect((await rtdb.ref(`series/${ID}/${minute}`).get()).val()).toBe(19.6);
    }
    // An old day is dropped when a new day starts.
    await rtdb.ref(`series/${ID}/2020-01-01`).set({ 1: 3 });
    await stateRef(ID).update({ seriesDay: "2020-01-02" });
    await ingest(token);
    expect(((await rtdb.ref(`series/${ID}/2020-01-01`).get()).val())).toBeNull();
  });

  it("keeps each 15-minute sample in the owner's day record, kept a year (D53)", async () => {
    const token = await registered();
    await ingest(token); // unassigned: no day record
    expect(await count(db.collection(C.readings))).toBe(0);
    await setOwner(ID, "userA");
    await stateRef(ID).update({ lastSampleAt: Date.now() - 901 * S });
    await ingest(token, { flowRate: 6.5 });
    const days = (await db.collection(C.readings).where("deviceId", "==", ID).get()).docs;
    expect(days).toHaveLength(1);
    const day = days[0]!.data();
    expect(day).toMatchObject({ ownerUid: "userA", deviceId: ID });
    expect(Object.values(day.rates as Record<string, number>)).toEqual([6.5]);
    expect((day.expireAt as Timestamp).toMillis()).toBeGreaterThan(Date.now() + 360 * 86_400_000);
    // Reassigning deletes it with the rest of the history (D20).
    await setOwner(ID, "userB");
    expect(await count(db.collection(C.readings))).toBe(0);
  });

  it("opens and closes problem records on status changes, owner only (D49)", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    await ingest(token, { flowStatus: "No Flow", flowRate: 0, trigger: "status_change" });
    expect(await count(problems())).toBe(0); // unassigned: nobody could read it

    await setOwner(ID, "userA");
    await ingest(token, { trigger: "status_change" });
    await ingest(token, { flowStatus: "No Flow", flowRate: 0, trigger: "status_change" });
    const open = (await problems().get()).docs;
    expect(open).toHaveLength(1);
    expect(open[0]!.data()).toMatchObject({
      ownerUid: "userA",
      type: "no_flow",
      endedAt: null,
      note: null,
    });
    expect(open[0]!.get("expireAt")).toBeInstanceOf(Timestamp);

    // Ended within 60 s: a blip, dropped.
    await ingest(token, { trigger: "status_change" });
    expect(await count(problems())).toBe(0);

    // Lasting longer: kept with its end time.
    await ingest(token, { flowStatus: "Low Flow", flowRate: 1, trigger: "status_change" });
    const id = (await problems().get()).docs[0]!.id;
    await db
      .collection(C.problems)
      .doc(id)
      .update({ startedAt: Timestamp.fromMillis(Date.now() - 300 * S) });
    await ingest(token, { trigger: "status_change" });
    const ended = await db.collection(C.problems).doc(id).get();
    expect(ended.get("endedAt")).toBeInstanceOf(Timestamp);
    expect((await state()).open ?? {}).toEqual({});
  });

  it("keeps abnormalSince through Normal -> Low -> No and clears it on Normal", async () => {
    const token = await registered();
    await ingest(token, { trigger: "status_change" });
    expect((await live()).abnormalSince ?? null).toBeNull();

    await ingest(token, { flowStatus: "Low Flow", flowRate: 1, trigger: "status_change" });
    const since = (await live()).abnormalSince as number;
    expect(typeof since).toBe("number");

    await ingest(token, { flowStatus: "No Flow", flowRate: 0, trigger: "status_change" });
    expect((await live()).abnormalSince).toBe(since);

    await ingest(token, { trigger: "status_change" });
    expect((await live()).abnormalSince ?? null).toBeNull();
  });

  it("keeps the low-voltage sleep flag on the live node", async () => {
    const token = await registered();
    await ingest(token, { batteryVoltage: 6.7, lowVoltageSleep: true });
    expect((await live()).lowVoltageSleep).toBe(true);
    await ingest(token);
    expect((await live()).lowVoltageSleep).toBe(false);
  });

  it("writes GPS to Firestore only when it moves", async () => {
    const token = await registered();
    await ingest(token);
    await dev().update({ gpsLat: 1 }); // a marker: rewritten only on a move
    await ingest(token);
    expect((await get(dev())).gpsLat).toBe(1);
    await ingest(token, { lat: 16.05 });
    expect((await get(dev())).gpsLat).toBe(16.05);
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

describe("alerts at the upload (D62)", () => {
  it("only when a flow problem is confirmed or the battery is low", async () => {
    const { alertMayBeDue } = await import("../src/device/deviceIngest");
    const now = Date.now();
    const base = {
      ownerUid: "u1",
      removed: false,
      online: true,
      lastSeen: now,
      flowStatus: "Normal Flow" as const,
      flowRate: 8,
      abnormalSince: null,
      statusChangedAt: now,
      batteryPercent: 80,
      chargingStatus: null,
      batteryFault: false,
      lowVoltageSleep: false,
      heartbeatS: 30,
    };
    expect(alertMayBeDue(base, now)).toBe(false);
    const dry = { ...base, flowStatus: "No Flow" as const, abnormalSince: now - 10_000 };
    expect(alertMayBeDue(dry, now)).toBe(false); // not yet 30 s
    expect(alertMayBeDue({ ...dry, abnormalSince: now - 30_000 }, now)).toBe(true);
    expect(alertMayBeDue({ ...base, batteryPercent: 15 }, now)).toBe(true);
    expect(alertMayBeDue({ ...dry, abnormalSince: now - 30_000, ownerUid: null }, now)).toBe(
      false,
    );
  });
});

describe("monitorDevices", () => {
  it("flips a silent device offline after two missed heartbeats and opens Offline", async () => {
    const token = await registered();
    const token2 = await registered(ID2);
    await setOwner(ID, "userA");
    await ingest(token, { heartbeatS: 30 });
    await ingest(token2, { heartbeatS: 30 }, ID2);

    await setLastSeen(61);
    const { flipped } = await runMonitorPass();
    expect(flipped).toEqual([ID]);
    expect((await live()).online).toBe(false);
    expect((await live(ID2)).online).toBe(true);
    const off = (await problems().get()).docs;
    expect(off.map((d) => d.get("type"))).toEqual(["offline"]);

    // Back: the Offline problem ends.
    await ingest(token, { heartbeatS: 30 });
    const back = await db.collection(C.problems).doc(off[0]!.id).get();
    expect(back.get("endedAt")).toBeInstanceOf(Timestamp);
  });

  it("keeps 3 min for firmware that does not report its heartbeat", async () => {
    const token = await registered();
    await ingest(token);
    await setLastSeen(120);
    expect((await runMonitorPass()).flipped).toEqual([]);
    await setLastSeen(181);
    expect((await runMonitorPass()).flipped).toEqual([ID]);
  });

  it("leaves a device online when an ingest lands before the flip transaction", async () => {
    const token = await registered();
    await ingest(token);
    await setLastSeen(181);
    await ingest(token); // lands between the read and the transaction
    expect(await flipOfflineIfStale(ID, Date.now())).toBeNull();
    expect((await live()).online).toBe(true);
  });
});

describe("removeDevice", () => {
  const admin = <T>(data: T) =>
    ({ auth: { uid: "admin1", token: { role: "admin" } }, data }) as unknown as CallableRequest<T>;

  it("a removed device gets 403 and keeps its data; restoring lets it back in (D42)", async () => {
    await allow();
    const token = await registered();
    expect((await ingest(token)).status).toBe(200);
    await liveRef(ID).update({ online: false });

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
