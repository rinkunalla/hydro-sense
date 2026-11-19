// Rules for History (D49) and the live channel (D48): problems in Firestore and
// /live, /state in the Realtime Database. Run with `npm run test:rules`.
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { get, ref, set, update, type Database } from "firebase/database";
import {
  Timestamp,
  addDoc,
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

let env: RulesTestEnvironment;
type Who = { fs: Firestore; rt: Database };
let userA: Who;
let userB: Who;
let admin: Who;
let anon: Who;

const who = (ctx: RulesTestContext): Who => ({
  fs: ctx.firestore() as unknown as Firestore,
  rt: ctx.database() as unknown as Database,
});

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836",
    firestore: { rules: readFileSync(path.resolve(process.cwd(), "../firestore.rules"), "utf8") },
    database: { rules: readFileSync(path.resolve(process.cwd(), "../database.rules.json"), "utf8") },
  });
  userA = who(env.authenticatedContext("userA", { role: "user" }));
  userB = who(env.authenticatedContext("userB", { role: "user" }));
  admin = who(env.authenticatedContext("admin1", { role: "admin" }));
  anon = who(env.unauthenticatedContext());
});

afterAll(async () => {
  await env.cleanup();
});

const problem = (ownerUid: string | null, ended: boolean) => ({
  ownerUid,
  deviceId: "DEVA",
  type: "no_flow",
  startedAt: Timestamp.fromMillis(1_800_000_000_000),
  endedAt: ended ? Timestamp.fromMillis(1_800_000_600_000) : null,
  note: null,
  expireAt: Timestamp.fromMillis(1_830_000_000_000),
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearDatabase();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const s = ctx.firestore() as unknown as Firestore;
    await setDoc(doc(s, "problems/endedA"), problem("userA", true));
    await setDoc(doc(s, "problems/openA"), problem("userA", false));
    await setDoc(doc(s, "problems/endedB"), problem("userB", true));
    await setDoc(doc(s, "admins/admin1"), { name: "A", status: "active" });
    await setDoc(doc(s, "readings/DEVA_2026-11-16"), {
      ownerUid: "userA",
      deviceId: "DEVA",
      day: "2026-11-16",
      rates: { "40": 6.5 },
    });
    const r = ctx.database() as unknown as Database;
    await set(ref(r, "live/DEVA"), { ownerUid: "userA", online: true, flowStatus: "Normal Flow" });
    await set(ref(r, "live/DEVB"), { ownerUid: "userB", online: true });
    await set(ref(r, "live/FREE"), { online: true }); // unassigned
    await set(ref(r, "state/DEVA"), { ownerUid: "userA", tokenHash: "secret" });
    await set(ref(r, "series/DEVA/2026-11-17"), { 600: 19.6 });
  });
});

describe("problems (D49)", () => {
  it("a user reads and lists only their own", async () => {
    await assertSucceeds(getDoc(doc(userA.fs, "problems/endedA")));
    await assertSucceeds(
      getDocs(query(collection(userA.fs, "problems"), where("ownerUid", "==", "userA"))),
    );
    await assertFails(getDoc(doc(userA.fs, "problems/endedB")));
    await assertFails(getDocs(collection(userA.fs, "problems")));
    await assertFails(getDoc(doc(admin.fs, "problems/endedA"))); // admins see no history (D24)
    await assertFails(getDoc(doc(anon.fs, "problems/endedA")));
  });

  it("only the server creates them", async () => {
    await assertFails(addDoc(collection(userA.fs, "problems"), problem("userA", true)));
    await assertFails(setDoc(doc(userA.fs, "problems/fake"), problem("userA", true)));
  });

  it("the owner adds, changes and clears a note of up to 100 characters, nothing else", async () => {
    await assertSucceeds(updateDoc(doc(userA.fs, "problems/endedA"), { note: "Valve closed" }));
    await assertSucceeds(updateDoc(doc(userA.fs, "problems/openA"), { note: "Checking" }));
    await assertSucceeds(updateDoc(doc(userA.fs, "problems/endedA"), { note: null }));
    await assertFails(updateDoc(doc(userA.fs, "problems/endedA"), { note: "x".repeat(101) }));
    await assertFails(updateDoc(doc(userA.fs, "problems/endedA"), { note: "   " }));
    await assertFails(updateDoc(doc(userA.fs, "problems/endedA"), { type: "low_flow" }));
    await assertFails(updateDoc(doc(userA.fs, "problems/endedA"), { endedAt: null }));
    await assertFails(updateDoc(doc(userA.fs, "problems/endedB"), { note: "mine?" }));
  });

  it("the owner deletes an ended problem, never an ongoing one or another user's", async () => {
    await assertFails(deleteDoc(doc(userA.fs, "problems/openA")));
    await assertFails(deleteDoc(doc(userA.fs, "problems/endedB")));
    await assertSucceeds(deleteDoc(doc(userA.fs, "problems/endedA")));
  });
});

describe("History graph readings (D53)", () => {
  it("only the owner reads a day; nobody writes", async () => {
    await assertSucceeds(getDoc(doc(userA.fs, "readings/DEVA_2026-11-16")));
    await assertFails(getDoc(doc(userB.fs, "readings/DEVA_2026-11-16")));
    await assertFails(getDoc(doc(admin.fs, "readings/DEVA_2026-11-16")));
    await assertFails(
      updateDoc(doc(userA.fs, "readings/DEVA_2026-11-16"), { rates: { "41": 99 } }),
    );
    await assertFails(deleteDoc(doc(userA.fs, "readings/DEVA_2026-11-16")));
  });
});

describe("live channel (D48)", () => {
  it("a user reads only their own device's live node", async () => {
    await assertSucceeds(get(ref(userA.rt, "live/DEVA")));
    await assertFails(get(ref(userA.rt, "live/DEVB")));
    await assertFails(get(ref(userA.rt, "live/FREE")));
    await assertFails(get(ref(userA.rt, "live"))); // no listing every device
    await assertSucceeds(get(ref(userB.rt, "live/DEVB")));
    await assertFails(get(ref(userB.rt, "live/DEVA")));
    await assertFails(getDoc(doc(userB.fs, "problems/endedA")));
  });

  it("admins and anonymous visitors read no live node (D24)", async () => {
    await assertFails(get(ref(admin.rt, "live/DEVA")));
    await assertFails(get(ref(anon.rt, "live/DEVA")));
  });

  it("only the owner reads a device's live series (D60)", async () => {
    await assertSucceeds(get(ref(userA.rt, "series/DEVA/2026-11-17")));
    await assertFails(get(ref(userB.rt, "series/DEVA/2026-11-17")));
    await assertFails(get(ref(admin.rt, "series/DEVA/2026-11-17")));
    await assertFails(set(ref(userA.rt, "series/DEVA/2026-11-17/601"), 5));
  });

  it("nobody reads server state or writes anything", async () => {
    await assertFails(get(ref(userA.rt, "state/DEVA")));
    await assertFails(get(ref(admin.rt, "state/DEVA")));
    await assertFails(update(ref(userA.rt, "live/DEVA"), { online: false }));
    await assertFails(set(ref(userA.rt, "live/DEVA/flowStatus"), "Normal Flow"));
    await assertFails(set(ref(userA.rt, "state/DEVA/tokenHash"), "mine"));
  });
});
