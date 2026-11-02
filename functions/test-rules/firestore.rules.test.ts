// Firestore rules tests (KICKOFF.md Phase 1). Run with `npm run test:rules` from
// the repo root, which starts the Firestore emulator first.
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  Timestamp,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  updateDoc,
  where,
  type Firestore,
} from "firebase/firestore";
import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";

const HOUR_MS = 3600 * 1000;
const DAY_MS = 24 * HOUR_MS;

let env: RulesTestEnvironment;
let client: Firestore;
let otherClient: Firestore;
let admin: Firestore;
let noRole: Firestore;
let anon: Firestore;

const db = (ctx: RulesTestContext) => ctx.firestore() as unknown as Firestore;

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836",
    firestore: {
      // Tests run with functions/ as the working directory.
      rules: readFileSync(path.resolve(process.cwd(), "../firestore.rules"), "utf8"),
    },
  });
  client = db(env.authenticatedContext("client1", { role: "client" }));
  otherClient = db(env.authenticatedContext("client2", { role: "client" }));
  admin = db(env.authenticatedContext("admin1", { role: "admin" }));
  noRole = db(env.authenticatedContext("someone", {}));
  anon = db(env.unauthenticatedContext());
});

afterAll(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const s = db(ctx);
    const device = (ownerUid: string | null, nickname: string) => ({
      ownerUid,
      nickname,
      flowStatus: "Normal Flow",
      flowRate: 4.2,
      lat: 16.04,
      lng: 120.33,
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2.0,
      pausedUntil: null,
    });
    await setDoc(doc(s, "config/system"), {
      clientUid: "client1",
      clientName: "C",
      clientEmail: "c@x.ph",
    });
    await setDoc(doc(s, "users/client1"), { role: "client", email: "c@x.ph" });
    await setDoc(doc(s, "users/client2"), { role: "client", email: "d@x.ph" });
    await setDoc(doc(s, "devices/DEV1"), device("client1", "Garden Line"));
    await setDoc(doc(s, "devices/DEV2"), device("client2", "Other"));
    await setDoc(doc(s, "devices/DEV3"), device(null, "Device 0003"));
    await setDoc(doc(s, "devices/DEV1/flow_logs/l1"), {
      flowStatus: "Normal Flow",
      trigger: "heartbeat",
    });
    await setDoc(doc(s, "devices/DEV3/flow_logs/l1"), {
      flowStatus: "Normal Flow",
      trigger: "heartbeat",
    });
    await setDoc(doc(s, "device_health/DEV1"), { ownerUid: "client1", online: true });
    await setDoc(doc(s, "device_health/DEV3"), { ownerUid: null, online: true });
    await setDoc(doc(s, "device_health/DEV1/battery_logs/b1"), { batteryVoltage: 7.9 });
    await setDoc(doc(s, "device_secrets/DEV1"), { tokenHash: "x" });
    await setDoc(doc(s, "allowed_devices/DEV1"), { addedAt: 1 });
    await setDoc(doc(s, "removed_devices/DEV9"), { removedAt: 1 });
    await setDoc(doc(s, "alert_state/DEV1__flow"), { active: false });
    await setDoc(doc(s, "alert_daily/2026-11-03"), { smsCount: 0 });
    await setDoc(doc(s, "ai_insights/client_summary"), { text: "All good." });
    await setDoc(doc(s, "ai_insights/admin_diagnostics"), { text: "Healthy." });
    await setDoc(doc(s, "error_logs/e1"), { deviceId: "DEV1", code: "SMS_FAILED", ts: 1 });
    await setDoc(doc(s, "unlisted/x"), { a: 1 });
  });
});

describe("client reads", () => {
  it("reads own device, health, flow logs and the summary", async () => {
    await assertSucceeds(getDoc(doc(client, "devices/DEV1")));
    await assertSucceeds(getDoc(doc(client, "device_health/DEV1")));
    await assertSucceeds(getDoc(doc(client, "devices/DEV1/flow_logs/l1")));
    await assertSucceeds(getDocs(collection(client, "devices/DEV1/flow_logs")));
    await assertSucceeds(getDoc(doc(client, "ai_insights/client_summary")));
    await assertSucceeds(getDoc(doc(client, "users/client1")));
  });

  it("lists own devices and health with an ownerUid filter only", async () => {
    await assertSucceeds(
      getDocs(query(collection(client, "devices"), where("ownerUid", "==", "client1"))),
    );
    await assertSucceeds(
      getDocs(query(collection(client, "device_health"), where("ownerUid", "==", "client1"))),
    );
    await assertFails(getDocs(collection(client, "devices")));
  });

  it("cannot read devices it does not own, or unadopted devices", async () => {
    await assertFails(getDoc(doc(client, "devices/DEV2")));
    await assertFails(getDoc(doc(client, "devices/DEV3")));
    await assertFails(getDoc(doc(client, "device_health/DEV3")));
    await assertFails(getDoc(doc(client, "devices/DEV3/flow_logs/l1")));
    await assertFails(getDoc(doc(otherClient, "devices/DEV1")));
  });

  it("cannot read admin-only or private data", async () => {
    await assertFails(getDoc(doc(client, "config/system")));
    await assertFails(getDoc(doc(client, "removed_devices/DEV9")));
    await assertFails(getDoc(doc(client, "allowed_devices/DEV1")));
    await assertFails(getDoc(doc(client, "device_health/DEV1/battery_logs/b1")));
    await assertFails(getDoc(doc(client, "ai_insights/admin_diagnostics")));
    await assertFails(getDoc(doc(client, "error_logs/e1")));
    await assertFails(getDoc(doc(client, "users/client2")));
  });
});

describe("client writes", () => {
  const pauseIn = (ms: number) => Timestamp.fromMillis(Date.now() + ms);

  it("changes nickname and pausedUntil with valid values", async () => {
    await assertSucceeds(updateDoc(doc(client, "devices/DEV1"), { nickname: "Kitchen" }));
    await assertSucceeds(updateDoc(doc(client, "devices/DEV1"), { nickname: "x".repeat(24) }));
    await assertSucceeds(updateDoc(doc(client, "devices/DEV1"), { pausedUntil: pauseIn(HOUR_MS) }));
    await assertSucceeds(
      updateDoc(doc(client, "devices/DEV1"), { pausedUntil: pauseIn(6 * DAY_MS) }),
    );
    await assertSucceeds(updateDoc(doc(client, "devices/DEV1"), { pausedUntil: null }));
    await assertSucceeds(
      updateDoc(doc(client, "devices/DEV1"), { nickname: "Both", pausedUntil: pauseIn(HOUR_MS) }),
    );
  });

  it("rejects invalid nicknames", async () => {
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { nickname: "" }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { nickname: "   " }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { nickname: "x".repeat(25) }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { nickname: 42 }));
  });

  it("rejects a pause over 7 days, in the past, or of the wrong type", async () => {
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { pausedUntil: pauseIn(8 * DAY_MS) }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { pausedUntil: pauseIn(-HOUR_MS) }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { pausedUntil: "tomorrow" }));
  });

  it("cannot change any other field, even alongside an allowed one", async () => {
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { flowStatus: "No Flow" }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { ownerUid: "client2" }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { normalFlowCutoff: 9 }));
    await assertFails(updateDoc(doc(client, "devices/DEV1"), { nickname: "Ok", lowFlowCutoff: 0 }));
  });

  it("cannot create, delete or edit devices it does not own", async () => {
    await assertFails(
      setDoc(doc(client, "devices/NEW1"), { ownerUid: "client1", nickname: "New" }),
    );
    await assertFails(deleteDoc(doc(client, "devices/DEV1")));
    await assertFails(updateDoc(doc(client, "devices/DEV2"), { nickname: "Mine now" }));
    await assertFails(updateDoc(doc(client, "devices/DEV3"), { nickname: "Mine now" }));
  });

  it("cannot write anything else", async () => {
    await assertFails(setDoc(doc(client, "users/client1"), { role: "admin" }));
    await assertFails(updateDoc(doc(client, "device_health/DEV1"), { online: false }));
    await assertFails(setDoc(doc(client, "devices/DEV1/flow_logs/l2"), { flowStatus: "x" }));
    await assertFails(setDoc(doc(client, "ai_insights/client_summary"), { text: "x" }));
  });
});

describe("admin", () => {
  it("cannot read flow data", async () => {
    await assertFails(getDoc(doc(admin, "devices/DEV1")));
    await assertFails(getDocs(collection(admin, "devices")));
    await assertFails(getDoc(doc(admin, "devices/DEV1/flow_logs/l1")));
    await assertFails(getDoc(doc(admin, "ai_insights/client_summary")));
  });

  it("reads health, logs, diagnostics, allow and removed lists, and config", async () => {
    await assertSucceeds(getDoc(doc(admin, "device_health/DEV1")));
    await assertSucceeds(getDoc(doc(admin, "device_health/DEV3")));
    await assertSucceeds(getDocs(collection(admin, "device_health")));
    await assertSucceeds(getDocs(collection(admin, "device_health/DEV1/battery_logs")));
    await assertSucceeds(getDocs(collection(admin, "error_logs")));
    await assertSucceeds(getDoc(doc(admin, "ai_insights/admin_diagnostics")));
    await assertSucceeds(getDocs(collection(admin, "removed_devices")));
    await assertSucceeds(getDocs(collection(admin, "allowed_devices")));
    await assertSucceeds(getDoc(doc(admin, "config/system")));
  });

  it("cannot read user docs or write anything", async () => {
    await assertFails(getDoc(doc(admin, "users/client1")));
    await assertFails(setDoc(doc(admin, "config/system"), { clientUid: "x" }));
    await assertFails(setDoc(doc(admin, "allowed_devices/NEW1"), { addedAt: 1 }));
    await assertFails(deleteDoc(doc(admin, "removed_devices/DEV9")));
    await assertFails(updateDoc(doc(admin, "device_health/DEV1"), { online: false }));
  });
});

describe("nobody", () => {
  const everyone = () => [client, otherClient, admin, noRole, anon];

  it("reads device_secrets, alert_state or alert_daily", async () => {
    for (const s of everyone()) {
      await assertFails(getDoc(doc(s, "device_secrets/DEV1")));
      await assertFails(getDoc(doc(s, "alert_state/DEV1__flow")));
      await assertFails(getDoc(doc(s, "alert_daily/2026-11-03")));
    }
  });

  it("reads or writes unlisted paths", async () => {
    for (const s of everyone()) {
      await assertFails(getDoc(doc(s, "unlisted/x")));
      await assertFails(setDoc(doc(s, "unlisted/y"), { a: 1 }));
    }
  });

  it("without a role or sign-in reads nothing", async () => {
    for (const s of [noRole, anon]) {
      await assertFails(getDoc(doc(s, "devices/DEV1")));
      await assertFails(getDoc(doc(s, "device_health/DEV1")));
      await assertFails(getDoc(doc(s, "ai_insights/client_summary")));
      await assertFails(getDoc(doc(s, "config/system")));
      await assertFails(getDoc(doc(s, "error_logs/e1")));
    }
  });
});
