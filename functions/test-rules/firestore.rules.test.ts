// Firestore rules tests. Run with `npm run test:rules` from
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
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  type Firestore,
} from "firebase/firestore";
import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";

const HOUR_MS = 3600 * 1000;

let env: RulesTestEnvironment;
let userA: Firestore;
let userB: Firestore;
let oldClient: Firestore; // v1 role, must get nothing
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
  userA = db(env.authenticatedContext("userA", { role: "user" }));
  userB = db(env.authenticatedContext("userB", { role: "user" }));
  oldClient = db(env.authenticatedContext("userA", { role: "client" }));
  admin = db(env.authenticatedContext("admin1", { role: "admin" }));
  noRole = db(env.authenticatedContext("someone", {}));
  anon = db(env.unauthenticatedContext());
});

afterAll(async () => {
  await env.cleanup();
});

const prefs = { push: true, sms: true, email: false };
const branch = (id: string, deviceIds: string[] = ["DEVA"]) => ({
  id,
  endName: `End ${id}`,
  endLat: 16.05,
  endLng: 120.34,
  deviceIds,
});
const pipeline = (branches = [branch("b1")]) => ({
  name: "Farm pipeline",
  source: { name: "Tank", lat: 16.04, lng: 120.33 },
  branches,
  updatedAt: serverTimestamp(),
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
      gpsLat: 16.04,
      gpsLng: 120.33,
      manualLat: null,
      manualLng: null,
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2.0,
    });
    const user = (name: string) => ({
      role: "user",
      name,
      email: `${name}@x.ph`,
      phone: "639171234567",
      passwordSet: true,
      deviceCount: 1,
      alertPrefs: prefs,
      status: "active",
    });
    await setDoc(doc(s, "users/userA"), user("a"));
    await setDoc(doc(s, "users/userB"), user("b"));
    await setDoc(doc(s, "users/userA/push_tokens/tokA"), { platform: "android", updatedAt: 1 });
    await setDoc(doc(s, "admins/admin1"), { name: "Ad", email: "ad@x.ph", status: "active" });
    await setDoc(doc(s, "admin_audit/a1"), { action: "user_deleted", targetId: "userB" });
    await setDoc(doc(s, "devices/DEVA"), device("userA", "Garden Line"));
    await setDoc(doc(s, "devices/DEVB"), device("userB", "Other"));
    await setDoc(doc(s, "devices/DEVU"), device(null, "Device 0003"));
    for (const id of ["DEVA", "DEVB", "DEVU"]) {
      await setDoc(doc(s, `devices/${id}/flow_logs/l1`), { flowStatus: "Normal Flow" });
    }
    await setDoc(doc(s, "device_health/DEVA"), { ownerUid: "userA", online: true });
    await setDoc(doc(s, "device_health/DEVB"), { ownerUid: "userB", online: true });
    await setDoc(doc(s, "device_health/DEVU"), { ownerUid: null, online: true });
    await setDoc(doc(s, "pipelines/userA"), { ...pipeline(), updatedAt: 1 });
    await setDoc(doc(s, "pipelines/userB"), { ...pipeline(), updatedAt: 1 });
    await setDoc(doc(s, "allowed_devices/DEVA"), { addedAt: 1, label: "Unit 1" });
    for (const p of [
      "device_secrets/DEVA",
      "phone_index/639171234567",
      "password_resets/userA",
      "admin_setup_tokens/admin2",
      "alert_state/DEVA__flow",
      "alert_daily/2026-11-14",
      "alert_daily/2026-11-14__userA",
      "rate_limits/register__1",
      "error_logs/e1",
      "settings/places",
      "config/system",
      "unlisted/x",
    ]) {
      await setDoc(doc(s, p), { a: 1 });
    }
  });
});

describe("a user reads only their own data", () => {
  it("reads own devices, health, flow logs, pipeline, profile and push tokens", async () => {
    await assertSucceeds(getDoc(doc(userA, "devices/DEVA")));
    await assertSucceeds(getDoc(doc(userA, "device_health/DEVA")));
    await assertSucceeds(getDocs(collection(userA, "devices/DEVA/flow_logs")));
    await assertSucceeds(getDoc(doc(userA, "pipelines/userA")));
    await assertSucceeds(getDoc(doc(userA, "users/userA")));
    await assertSucceeds(getDoc(doc(userA, "users/userA/push_tokens/tokA")));
  });

  it("lists own devices and health only with an ownerUid filter", async () => {
    await assertSucceeds(
      getDocs(query(collection(userA, "devices"), where("ownerUid", "==", "userA"))),
    );
    await assertSucceeds(
      getDocs(query(collection(userA, "device_health"), where("ownerUid", "==", "userA"))),
    );
    await assertFails(getDocs(collection(userA, "devices")));
    await assertFails(
      getDocs(query(collection(userA, "devices"), where("ownerUid", "==", "userB"))),
    );
  });

  it("never reads another user's or an unassigned device", async () => {
    for (const id of ["DEVB", "DEVU"]) {
      await assertFails(getDoc(doc(userA, `devices/${id}`)));
      await assertFails(getDoc(doc(userA, `device_health/${id}`)));
      await assertFails(getDocs(collection(userA, `devices/${id}/flow_logs`)));
    }
    await assertFails(getDoc(doc(userA, "pipelines/userB")));
    await assertFails(getDoc(doc(userA, "users/userB")));
    await assertFails(getDoc(doc(userB, "users/userA/push_tokens/tokA")));
  });

  it("reads no admin data", async () => {
    await assertFails(getDoc(doc(userA, "admins/admin1")));
    await assertFails(getDocs(collection(userA, "admin_audit")));
    await assertFails(getDoc(doc(userA, "allowed_devices/DEVA")));
  });

  it("the v1 'client' role gets nothing", async () => {
    await assertFails(getDoc(doc(oldClient, "devices/DEVA")));
    await assertFails(getDoc(doc(oldClient, "users/userA")));
  });
});

describe("user writes", () => {
  it("changes the nickname (1 to 24 characters)", async () => {
    await assertSucceeds(updateDoc(doc(userA, "devices/DEVA"), { nickname: "Kitchen" }));
    await assertSucceeds(updateDoc(doc(userA, "devices/DEVA"), { nickname: "x".repeat(24) }));
    for (const bad of ["", "   ", "x".repeat(25), 42]) {
      await assertFails(updateDoc(doc(userA, "devices/DEVA"), { nickname: bad }));
    }
  });

  it("sets and clears the manual pin, both values or neither", async () => {
    const pin = doc(userA, "devices/DEVA");
    await assertSucceeds(updateDoc(pin, { manualLat: 16.1, manualLng: 120.4 }));
    await assertSucceeds(updateDoc(pin, { manualLat: null, manualLng: null }));
    await assertFails(updateDoc(pin, { manualLat: 16.1 }));
    await assertFails(updateDoc(pin, { manualLat: 16.1, manualLng: null }));
    await assertFails(updateDoc(pin, { manualLat: 91, manualLng: 120 }));
    await assertFails(updateDoc(pin, { manualLat: 16, manualLng: 181 }));
    await assertFails(updateDoc(pin, { manualLat: "16", manualLng: "120" }));
  });

  it("sets its own Low flow limit (1 to 30 L/min) or goes back to automatic", async () => {
    const d = doc(userA, "devices/DEVA");
    await assertSucceeds(updateDoc(d, { userNormalCutoff: 5 }));
    await assertSucceeds(updateDoc(d, { userNormalCutoff: 1.0 }));
    await assertSucceeds(updateDoc(d, { userNormalCutoff: 30 }));
    await assertSucceeds(updateDoc(d, { userNormalCutoff: null }));
    for (const bad of [0.5, 30.5, -1, "5"]) {
      await assertFails(updateDoc(d, { userNormalCutoff: bad }));
    }
    await assertFails(updateDoc(doc(userB, "devices/DEVA"), { userNormalCutoff: 5 }));
  });

  it("changes no other device field, even alongside an allowed one", async () => {
    const d = doc(userA, "devices/DEVA");
    await assertFails(updateDoc(d, { flowStatus: "No Flow" }));
    await assertFails(updateDoc(d, { ownerUid: "userB" }));
    await assertFails(updateDoc(d, { gpsLat: 1, gpsLng: 1 }));
    await assertFails(updateDoc(d, { nickname: "Ok", lowFlowCutoff: 0 }));
    await assertFails(updateDoc(d, { pausedUntil: Timestamp.fromMillis(Date.now() + HOUR_MS) }));
    await assertFails(deleteDoc(d));
    await assertFails(setDoc(doc(userA, "devices/NEW1"), { ownerUid: "userA", nickname: "N" }));
    await assertFails(updateDoc(doc(userA, "devices/DEVB"), { nickname: "Mine" }));
    await assertFails(updateDoc(doc(userA, "devices/DEVU"), { nickname: "Mine" }));
  });

  it("changes only alertPrefs on the own profile, as exactly three booleans", async () => {
    const me = doc(userA, "users/userA");
    await assertSucceeds(updateDoc(me, { alertPrefs: { push: false, sms: true, email: true } }));
    await assertFails(updateDoc(me, { alertPrefs: { push: false, sms: true } }));
    await assertFails(updateDoc(me, { alertPrefs: { ...prefs, extra: true } }));
    await assertFails(updateDoc(me, { alertPrefs: { push: "yes", sms: true, email: true } }));
    await assertFails(updateDoc(me, { name: "Renamed" }));
    await assertFails(updateDoc(me, { phone: "639170000000" }));
    await assertFails(updateDoc(me, { role: "admin" }));
    await assertFails(updateDoc(me, { status: "suspended", alertPrefs: prefs }));
    await assertFails(updateDoc(doc(userA, "users/userB"), { alertPrefs: prefs }));
  });

  it("deletes own push registration but never writes one (claimPushToken does)", async () => {
    await assertSucceeds(deleteDoc(doc(userA, "users/userA/push_tokens/tokA")));
    await assertFails(
      setDoc(doc(userA, "users/userA/push_tokens/tokNew"), {
        platform: "android",
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(deleteDoc(doc(userB, "users/userA/push_tokens/tokA")));
  });

  it("writes own pipeline within the size and shape limits", async () => {
    const p = doc(userA, "pipelines/userA");
    await assertSucceeds(setDoc(p, pipeline()));
    const ten = Array.from({ length: 10 }, (_, i) => branch(`b${i}`));
    await assertSucceeds(setDoc(p, pipeline(ten)));
    await assertSucceeds(setDoc(p, pipeline([branch("b1", Array(50).fill("DEVA"))])));
    await assertSucceeds(deleteDoc(p));

    await assertFails(setDoc(p, pipeline([...ten, branch("b10")])));
    await assertFails(setDoc(p, pipeline([branch("b1", Array(51).fill("DEVA"))])));
    await assertFails(setDoc(p, { ...pipeline(), name: "x".repeat(41) }));
    await assertFails(setDoc(p, { ...pipeline(), name: "" }));
    await assertFails(setDoc(p, { ...pipeline(), extra: 1 }));
    await assertFails(setDoc(p, { ...pipeline(), updatedAt: 1 }));
    await assertFails(setDoc(p, { ...pipeline(), source: { name: "Tank", lat: 99, lng: 120 } }));
    await assertFails(setDoc(p, pipeline([{ ...branch("b1"), endLat: "16" }])));
    await assertFails(setDoc(p, pipeline([{ ...branch("b1"), owner: "x" }])));
    await assertFails(setDoc(p, pipeline([{ ...branch("b1"), endName: "y".repeat(41) }])));
    await assertFails(setDoc(doc(userA, "pipelines/userB"), pipeline()));
  });

  it("writes nothing server-owned", async () => {
    await assertFails(updateDoc(doc(userA, "device_health/DEVA"), { online: false }));
    await assertFails(setDoc(doc(userA, "devices/DEVA/flow_logs/l2"), { flowStatus: "x" }));
    await assertFails(setDoc(doc(userA, "phone_index/639170000000"), { uid: "userA" }));
    await assertFails(setDoc(doc(userA, "users/userC"), { role: "user" }));
  });
});

describe("admin", () => {
  it("reads users, admins, the audit log and the allowlist", async () => {
    await assertSucceeds(getDocs(collection(admin, "users")));
    await assertSucceeds(getDoc(doc(admin, "users/userA")));
    await assertSucceeds(getDocs(collection(admin, "admins")));
    await assertSucceeds(getDocs(collection(admin, "admin_audit")));
    await assertSucceeds(getDocs(collection(admin, "allowed_devices")));
  });

  it("never reads devices, health, flow logs, pipelines or push tokens", async () => {
    await assertFails(getDoc(doc(admin, "devices/DEVA")));
    await assertFails(getDocs(collection(admin, "devices")));
    await assertFails(getDoc(doc(admin, "device_health/DEVA")));
    await assertFails(getDocs(collection(admin, "device_health")));
    await assertFails(getDocs(collection(admin, "devices/DEVA/flow_logs")));
    await assertFails(getDoc(doc(admin, "pipelines/userA")));
    await assertFails(getDoc(doc(admin, "users/userA/push_tokens/tokA")));
    await assertFails(getDoc(doc(admin, "config/system")));
  });

  it("writes nothing directly (callables do the work)", async () => {
    await assertFails(updateDoc(doc(admin, "users/userA"), { name: "x" }));
    await assertFails(updateDoc(doc(admin, "users/userA"), { alertPrefs: prefs }));
    await assertFails(setDoc(doc(admin, "admins/admin2"), { status: "active" }));
    await assertFails(setDoc(doc(admin, "allowed_devices/NEW1"), { addedAt: 1 }));
  });
});

describe("an admin claim without an active record", () => {
  it("reads nothing: invited, removed or unknown admins", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(db(ctx), "admins/admin2"), { status: "invited" });
    });
    const invited = db(env.authenticatedContext("admin2", { role: "admin" }));
    const removed = db(env.authenticatedContext("admin9", { role: "admin" }));
    for (const s of [invited, removed]) {
      await assertFails(getDocs(collection(s, "users")));
      await assertFails(getDocs(collection(s, "admins")));
      await assertFails(getDocs(collection(s, "admin_audit")));
      await assertFails(getDocs(collection(s, "allowed_devices")));
    }
  });
});

describe("the audit log is immutable", () => {
  it("nobody creates, changes or deletes an entry", async () => {
    for (const s of [admin, userA, noRole, anon]) {
      await assertFails(setDoc(doc(s, "admin_audit/a2"), { action: "user_restored" }));
      await assertFails(updateDoc(doc(s, "admin_audit/a1"), { targetId: "x" }));
      await assertFails(deleteDoc(doc(s, "admin_audit/a1")));
    }
  });
});

describe("nobody", () => {
  const everyone = () => [userA, userB, oldClient, admin, noRole, anon];

  it("reads server-only collections", async () => {
    for (const s of everyone()) {
      for (const p of [
        "device_secrets/DEVA",
        "phone_index/639171234567",
        "password_resets/userA",
        "admin_setup_tokens/admin2",
        "alert_state/DEVA__flow",
        "alert_daily/2026-11-14",
        "alert_daily/2026-11-14__userA",
        "rate_limits/register__1",
        "error_logs/e1",
        "settings/places",
      ]) {
        await assertFails(getDoc(doc(s, p)));
      }
      await assertFails(getDocs(collection(s, "error_logs")));
    }
  });

  it("reads or writes paths removed in v2 or never listed", async () => {
    for (const s of everyone()) {
      for (const p of [
        "config/system",
        "removed_devices/DEVA",
        "ai_insights/client_summary",
        "device_health/DEVA/battery_logs/b1",
        "unlisted/x",
      ]) {
        await assertFails(getDoc(doc(s, p)));
      }
      await assertFails(setDoc(doc(s, "unlisted/y"), { a: 1 }));
    }
  });

  it("without a role or sign-in reads nothing", async () => {
    for (const s of [noRole, anon]) {
      await assertFails(getDoc(doc(s, "devices/DEVA")));
      await assertFails(getDoc(doc(s, "users/userA")));
      await assertFails(getDoc(doc(s, "admins/admin1")));
      await assertFails(getDoc(doc(s, "pipelines/userA")));
    }
  });
});
