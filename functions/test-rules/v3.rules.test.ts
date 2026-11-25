// v3 rules (D62 to D66): one organization. Every active member reads every
// device, its health, History and the one pipeline; only admins write where a
// rule allows it; staff write nothing but their own push registrations.
// Run with `npm run test:rules` from the repo root (starts the emulators).
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { get, ref, set, type Database } from "firebase/database";
import {
  Timestamp,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
  type Firestore,
} from "firebase/firestore";
import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";

let env: RulesTestEnvironment;
type Who = { fs: Firestore; rt: Database };
let staffA: Who;
let staffB: Who;
let disabledStaff: Who;
let admin: Who;
let invitedAdmin: Who;
let oldClient: Who;
let noRole: Who;
let anon: Who;

const who = (ctx: RulesTestContext): Who => ({
  fs: ctx.firestore() as unknown as Firestore,
  rt: ctx.database() as unknown as Database,
});

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836",
    // Tests run with functions/ as the working directory.
    firestore: { rules: readFileSync(path.resolve(process.cwd(), "../firestore.rules"), "utf8") },
    database: {
      rules: readFileSync(path.resolve(process.cwd(), "../database.rules.json"), "utf8"),
    },
  });
  staffA = who(env.authenticatedContext("staffA", { role: "user" }));
  staffB = who(env.authenticatedContext("staffB", { role: "user" }));
  disabledStaff = who(env.authenticatedContext("staffOff", { role: "user" }));
  admin = who(env.authenticatedContext("admin1", { role: "admin" }));
  invitedAdmin = who(env.authenticatedContext("admin2", { role: "admin" }));
  oldClient = who(env.authenticatedContext("client1", { role: "client" }));
  noRole = who(env.authenticatedContext("someone", {}));
  anon = who(env.unauthenticatedContext());
});

afterAll(async () => {
  await env.cleanup();
});

const branch = (id: string) => ({
  id,
  endName: `End ${id}`,
  endLat: 16.05,
  endLng: 120.34,
  deviceIds: ["DEVA"],
});
const pipeline = (branches = [branch("b1")]) => ({
  name: "Main line",
  source: { name: "Spring", lat: 16.04, lng: 120.33 },
  branches,
  updatedAt: serverTimestamp(),
});
const problem = (ended: boolean) => ({
  deviceId: "DEVA",
  type: "no_flow",
  startedAt: Timestamp.fromMillis(1_800_000_000_000),
  endedAt: ended ? Timestamp.fromMillis(1_800_000_600_000) : null,
  expireAt: Timestamp.fromMillis(1_830_000_000_000),
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearDatabase();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const s = ctx.firestore() as unknown as Firestore;
    const staff = (name: string, status: string) => ({
      role: "user",
      name,
      username: name.toLowerCase(),
      email: null,
      phone: null,
      status,
    });
    await setDoc(doc(s, "users/staffA"), staff("Ana", "active"));
    await setDoc(doc(s, "users/staffB"), staff("Ben", "active"));
    await setDoc(doc(s, "users/staffOff"), staff("Off", "disabled"));
    await setDoc(doc(s, "users/staffA/push_tokens/fidA"), { platform: "android", fid: "fidA" });
    await setDoc(doc(s, "admins/admin1"), { name: "Owner", email: "o@x.ph", status: "active" });
    await setDoc(doc(s, "admins/admin2"), { name: "New", email: "n@x.ph", status: "invited" });
    await setDoc(doc(s, "devices/DEVA"), { nickname: "Main pipe", sensorType: "yf_s201" });
    await setDoc(doc(s, "devices/DEVA/flow_logs/l1"), { flowRate: 4 });
    await setDoc(doc(s, "device_health/DEVA"), { registeredAt: null, firmware: "0.3.0" });
    await setDoc(doc(s, "problems/open1"), problem(false));
    await setDoc(doc(s, "problems/ended1"), problem(true));
    await setDoc(doc(s, "readings/DEVA_2027-01-15"), { deviceId: "DEVA", rates: { "0": 4 } });
    await setDoc(doc(s, "pipelines/main"), pipeline());
    await setDoc(doc(s, "allowed_devices/DEVA"), { addedAt: Timestamp.now() });
    for (const p of [
      "device_secrets/DEVA",
      "phone_index/639171234567",
      "alert_state/DEVA__flow",
      "alert_daily/2027-01-15",
      "rate_limits/register__1",
      "error_logs/e1",
      "admin_setup_tokens/admin2",
    ]) {
      await setDoc(doc(s, p), { x: 1 });
    }
    const r = ctx.database() as unknown as Database;
    await set(ref(r, "members"), { staffA: true, staffB: true, admin1: true });
    await set(ref(r, "live/DEVA"), { online: true, flowRate: 4 });
    await set(ref(r, "state/DEVA"), { tokenHash: "x" });
    await set(ref(r, "series/DEVA/2027-01-15/600"), 4);
  });
});

const members = () => [staffA, staffB, admin];
const outsiders = () => [disabledStaff, invitedAdmin, oldClient, noRole, anon];

describe("every active member reads everything about every device", () => {
  const paths = [
    "devices/DEVA",
    "devices/DEVA/flow_logs/l1",
    "device_health/DEVA",
    "problems/open1",
    "readings/DEVA_2027-01-15",
    "pipelines/main",
  ];

  it("staff and admins read every device path", async () => {
    for (const w of members()) {
      for (const p of paths) await assertSucceeds(getDoc(doc(w.fs, p)));
      await assertSucceeds(getDocs(collection(w.fs, "devices")));
      await assertSucceeds(getDocs(collection(w.fs, "problems")));
    }
  });

  it("disabled staff, invited admins, old roles and strangers read nothing", async () => {
    for (const w of outsiders()) {
      for (const p of paths) await assertFails(getDoc(doc(w.fs, p)));
      await assertFails(getDocs(collection(w.fs, "devices")));
    }
  });
});

describe("only the callables change devices", () => {
  it("nobody writes a device, its health or its flow logs directly", async () => {
    for (const w of [...members(), ...outsiders()]) {
      await assertFails(updateDoc(doc(w.fs, "devices/DEVA"), { nickname: "Renamed" }));
      await assertFails(setDoc(doc(w.fs, "devices/DEVB"), { nickname: "New" }));
      await assertFails(updateDoc(doc(w.fs, "device_health/DEVA"), { firmware: "9" }));
      await assertFails(setDoc(doc(w.fs, "devices/DEVA/flow_logs/l2"), { flowRate: 1 }));
    }
  });
});

describe("History", () => {
  it("only an admin deletes, and only an ended problem", async () => {
    await assertFails(deleteDoc(doc(staffA.fs, "problems/ended1")));
    await assertFails(deleteDoc(doc(admin.fs, "problems/open1")));
    await assertSucceeds(deleteDoc(doc(admin.fs, "problems/ended1")));
  });

  it("nobody creates or changes a problem or a reading (no notes in v3)", async () => {
    for (const w of members()) {
      await assertFails(updateDoc(doc(w.fs, "problems/ended1"), { note: "Pipe fixed" }));
      await assertFails(setDoc(doc(w.fs, "problems/new1"), problem(false)));
      await assertFails(updateDoc(doc(w.fs, "readings/DEVA_2027-01-15"), { rates: {} }));
    }
  });
});

describe("the one pipeline", () => {
  it("the admin writes a valid pipelines/main; staff cannot", async () => {
    await assertSucceeds(
      setDoc(doc(admin.fs, "pipelines/main"), pipeline([branch("b1"), branch("b2")])),
    );
    await assertFails(setDoc(doc(staffA.fs, "pipelines/main"), pipeline()));
    await assertFails(deleteDoc(doc(staffA.fs, "pipelines/main")));
  });

  it("refuses other pipeline docs and oversized or malformed pipelines", async () => {
    await assertFails(setDoc(doc(admin.fs, "pipelines/admin1"), pipeline()));
    const eleven = Array.from({ length: 11 }, (_, i) => branch(`b${i}`));
    await assertFails(setDoc(doc(admin.fs, "pipelines/main"), pipeline(eleven)));
    await assertFails(setDoc(doc(admin.fs, "pipelines/main"), { ...pipeline(), extra: 1 }));
    const big = { ...branch("b1"), deviceIds: Array.from({ length: 51 }, (_, i) => `D${i}`) };
    await assertFails(setDoc(doc(admin.fs, "pipelines/main"), pipeline([big])));
  });

  it("keeps a map direction between -180 and 180 degrees; staff cannot set it", async () => {
    for (const rotation of [-179.5, 0, 35, 180]) {
      await assertSucceeds(setDoc(doc(admin.fs, "pipelines/main"), { ...pipeline(), rotation }));
    }
    for (const rotation of [-180, 181, 360, "north"]) {
      await assertFails(setDoc(doc(admin.fs, "pipelines/main"), { ...pipeline(), rotation }));
    }
    await assertFails(
      setDoc(doc(staffA.fs, "pipelines/main"), { ...pipeline(), rotation: 90 }),
    );
  });
});

describe("accounts", () => {
  it("staff read only their own record and change nothing", async () => {
    await assertSucceeds(getDoc(doc(staffA.fs, "users/staffA")));
    await assertFails(getDoc(doc(staffA.fs, "users/staffB")));
    await assertFails(updateDoc(doc(staffA.fs, "users/staffA"), { name: "Anna" }));
    await assertFails(
      updateDoc(doc(staffA.fs, "users/staffA"), {
        alertPrefs: { push: true, sms: true, email: true },
      }),
    );
  });

  it("admins read staff and admins; staff read neither admins nor the allowlist", async () => {
    await assertSucceeds(getDoc(doc(admin.fs, "users/staffB")));
    await assertSucceeds(getDoc(doc(admin.fs, "admins/admin2")));
    await assertSucceeds(getDoc(doc(admin.fs, "allowed_devices/DEVA")));
    await assertFails(getDoc(doc(staffA.fs, "admins/admin1")));
    await assertFails(getDoc(doc(staffA.fs, "allowed_devices/DEVA")));
    await assertFails(updateDoc(doc(admin.fs, "users/staffB"), { name: "X" }));
  });

  it("staff read and delete only their own push registrations, never create one", async () => {
    await assertSucceeds(getDoc(doc(staffA.fs, "users/staffA/push_tokens/fidA")));
    await assertFails(getDoc(doc(staffB.fs, "users/staffA/push_tokens/fidA")));
    await assertFails(setDoc(doc(staffA.fs, "users/staffA/push_tokens/fidX"), { fid: "fidX" }));
    await assertSucceeds(deleteDoc(doc(staffA.fs, "users/staffA/push_tokens/fidA")));
  });
});

describe("server-only and unlisted paths", () => {
  it("nobody reads or writes them", async () => {
    const paths = [
      "device_secrets/DEVA",
      "phone_index/639171234567",
      "alert_state/DEVA__flow",
      "alert_daily/2027-01-15",
      "rate_limits/register__1",
      "error_logs/e1",
      "admin_setup_tokens/admin2",
      "admin_audit/a1",
      "password_resets/staffA",
      "somewhere/else",
    ];
    for (const w of [...members(), ...outsiders()]) {
      for (const p of paths) {
        await assertFails(getDoc(doc(w.fs, p)));
        await assertFails(setDoc(doc(w.fs, p), { x: 1 }));
      }
    }
  });
});

describe("live channel (Realtime Database)", () => {
  it("members read every live node and series; nobody writes them", async () => {
    for (const w of members()) {
      await assertSucceeds(get(ref(w.rt, "live/DEVA")));
      await assertSucceeds(get(ref(w.rt, "live")));
      await assertSucceeds(get(ref(w.rt, "series/DEVA")));
      await assertFails(set(ref(w.rt, "live/DEVA/online"), false));
      await assertFails(set(ref(w.rt, "series/DEVA/2027-01-15/601"), 1));
    }
  });

  it("anyone not in /members reads nothing, and nobody reads /state or /members", async () => {
    for (const w of outsiders()) {
      await assertFails(get(ref(w.rt, "live/DEVA")));
      await assertFails(get(ref(w.rt, "series/DEVA")));
    }
    for (const w of [...members(), ...outsiders()]) {
      await assertFails(get(ref(w.rt, "state/DEVA")));
      await assertFails(get(ref(w.rt, "members")));
      await assertFails(set(ref(w.rt, "members/someone"), true));
    }
  });
});
