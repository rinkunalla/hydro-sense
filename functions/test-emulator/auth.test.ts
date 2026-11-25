// v3 acceptance tests for accounts: staff accounts the admin manages (D64)
// and admin accounts (D23, D40, D65 mobile). In-process against the Auth,
// Firestore and Realtime Database emulators with fake providers. Run WITHOUT
// the Functions emulator (test:inprocess).
import { getAuth } from "firebase-admin/auth";
import type { CallableRequest } from "firebase-functions/https";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import {
  completeAdminSetup,
  listAdmins,
  removeAdmin,
  requestAdminSetup,
  signOutEverywhere,
  syncMyAdmin,
  updateMyAdminMobile,
  updateMyAdminName,
} from "../src/admin/admins";
import {
  adminListStaff,
  createStaff,
  deleteStaff,
  resetStaffPassword,
  updateStaff,
} from "../src/admin/staff";
import { claimPushToken } from "../src/alerts/pushTokens";
import { C, db, rtdb, ts } from "../src/lib/db";
import { setProviders, type Providers } from "../src/lib/providers";
import { staffLoginEmail } from "../src/lib/userInput";

const PROJECT = process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836";
const FIRESTORE = process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080";
const AUTH = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099";

class Fake implements Providers {
  mail: { to: string; subject: string; text: string }[] = [];
  sms = { send: async () => undefined };
  email = {
    send: async (to: string, subject: string, text: string) =>
      void this.mail.push({ to, subject, text }),
  };
  push = { send: async (fids: string[]) => ({ sent: fids.length, stale: [] as string[] }) };
}

let fake: Fake;

const call = <T>(data: T, auth?: { uid: string; token: Record<string, unknown> }) =>
  ({ data, ...(auth ? { auth } : {}) }) as unknown as CallableRequest<T>;
const asAdmin = <T>(data: T, uid = "admin1") => call(data, { uid, token: { role: "admin" } });
const asStaff = <T>(data: T, uid: string) => call(data, { uid, token: { role: "user" } });

/** Signs in on the Auth emulator; true when the password works. */
async function signsIn(email: string, password: string): Promise<boolean> {
  const res = await fetch(
    `http://${AUTH}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    },
  );
  return res.ok;
}

const codeOf = async (p: Promise<unknown>) =>
  p.then(
    () => "ok",
    (e: { details?: { code?: string } }) => `${e.details?.code}`,
  );

const member = async (uid: string) => (await rtdb.ref(`members/${uid}`).get()).val();

const newStaff = (
  o: Partial<{ name: string; username: string; mobile: string; email: string }> = {},
) =>
  createStaff.run(
    asAdmin({
      name: o.name ?? "Juan Dela Cruz",
      username: o.username ?? "juan",
      password: "first-pass-1",
      ...(o.mobile !== undefined ? { mobile: o.mobile } : {}),
      ...(o.email !== undefined ? { email: o.email } : {}),
    }),
  );

beforeEach(async () => {
  await rtdb.ref().set(null);
  await fetch(`http://${FIRESTORE}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {
    method: "DELETE",
  });
  await fetch(`http://${AUTH}/emulator/v1/projects/${PROJECT}/accounts`, { method: "DELETE" });
  fake = new Fake();
  setProviders(fake);
  await db
    .collection(C.admins)
    .doc("admin1")
    .set({ name: "Dana", email: "dana@example.com", status: "active" });
});

afterAll(() => setProviders(null));

describe("staff accounts (D64)", () => {
  it("the admin creates a staff member who signs in with username and password", async () => {
    const { uid } = await newStaff({ username: "Juan", mobile: "0917 123 4567" });
    expect((await db.collection(C.users).doc(uid).get()).data()).toMatchObject({
      role: "user",
      name: "Juan Dela Cruz",
      username: "juan",
      phone: "639171234567",
      email: null,
      status: "active",
    });
    expect((await getAuth().getUser(uid)).customClaims).toEqual({ role: "user" });
    expect(await signsIn(staffLoginEmail("juan"), "first-pass-1")).toBe(true);
    expect((await db.collection(C.phoneIndex).doc("639171234567").get()).get("uid")).toBe(uid);
    expect(await member(uid)).toBe(true);
  });

  it("refuses a used username or mobile and leaves no half-made account", async () => {
    await newStaff({ username: "juan", mobile: "09171234567" });
    expect(await codeOf(newStaff({ username: "juan" }))).toBe("USERNAME_IN_USE");
    expect(await codeOf(newStaff({ username: "pedro", mobile: "+639171234567" }))).toBe(
      "PHONE_IN_USE",
    );
    await db.collection(C.admins).doc("admin1").update({ phone: "639170000009" });
    await db.collection(C.phoneIndex).doc("639170000009").set({ uid: "admin1" });
    expect(await codeOf(newStaff({ username: "maria", mobile: "09170000009" }))).toBe(
      "PHONE_IN_USE",
    );
    const staff = await db.collection(C.users).get();
    expect(staff.size).toBe(1);
    expect((await getAuth().listUsers()).users).toHaveLength(1);
  });

  it("validates input and refuses staff and strangers", async () => {
    expect(
      await codeOf(createStaff.run(asAdmin({ name: "Juan", username: "juan", password: "short" }))),
    ).toBe("PASSWORD_WEAK");
    expect(
      await codeOf(
        createStaff.run(
          asAdmin({ name: "Juan", username: "juan", password: "first-pass-1", mobile: "123" }),
        ),
      ),
    ).toBe("PHONE_INVALID");
    expect(
      await codeOf(
        createStaff.run(asStaff({ name: "X", username: "xx1", password: "first-pass-1" }, "s1")),
      ),
    ).toBe("NOT_ADMIN");
    expect(await codeOf(createStaff.run(call({})))).toBe("NOT_ADMIN");
  });

  it("lists staff with contacts and status for the Staff page; admins only", async () => {
    const { uid } = await newStaff({ email: "Juan@Example.com" });
    const { staff } = await adminListStaff.run(asAdmin({}));
    expect(staff).toEqual([
      expect.objectContaining({
        uid,
        username: "juan",
        email: "juan@example.com",
        phone: null,
        status: "active",
      }),
    ]);
    expect(await codeOf(adminListStaff.run(asStaff({}, uid)))).toBe("NOT_ADMIN");
  });

  it("updates name, username and contacts; removing a contact frees the number", async () => {
    const { uid } = await newStaff({ mobile: "09171234567", email: "juan@example.com" });
    await updateStaff.run(
      asAdmin({ uid, name: "Juan D.", username: "jdc", mobile: "09170000002", email: null }),
    );
    expect((await db.collection(C.users).doc(uid).get()).data()).toMatchObject({
      name: "Juan D.",
      username: "jdc",
      phone: "639170000002",
      email: null,
    });
    expect(await signsIn(staffLoginEmail("jdc"), "first-pass-1")).toBe(true);
    expect(await signsIn(staffLoginEmail("juan"), "first-pass-1")).toBe(false);
    expect((await db.collection(C.phoneIndex).doc("639171234567").get()).exists).toBe(false);

    await updateStaff.run(asAdmin({ uid, mobile: "" }));
    expect((await db.collection(C.users).doc(uid).get()).get("phone")).toBeNull();
    expect((await db.collection(C.phoneIndex).doc("639170000002").get()).exists).toBe(false);
  });

  it("disabling refuses sign-in, ends live access and staff callables; enabling undoes it", async () => {
    const { uid } = await newStaff();
    await updateStaff.run(asAdmin({ uid, disabled: true }));
    expect(await signsIn(staffLoginEmail("juan"), "first-pass-1")).toBe(false);
    expect(await member(uid)).toBeNull();
    expect((await db.collection(C.users).doc(uid).get()).get("status")).toBe("disabled");
    expect(await codeOf(claimPushToken.run(asStaff({ fid: "fid_phone_1" }, uid)))).toBe("NOT_USER");

    await updateStaff.run(asAdmin({ uid, disabled: false }));
    expect(await signsIn(staffLoginEmail("juan"), "first-pass-1")).toBe(true);
    expect(await member(uid)).toBe(true);
  });

  it("only the admin resets a password, and the old sessions end", async () => {
    const { uid } = await newStaff();
    const startS = Math.floor(Date.now() / 1000);
    await resetStaffPassword.run(asAdmin({ uid, password: "second-pass-2" }));
    expect(await signsIn(staffLoginEmail("juan"), "first-pass-1")).toBe(false);
    expect(await signsIn(staffLoginEmail("juan"), "second-pass-2")).toBe(true);
    const after = (await getAuth().getUser(uid)).tokensValidAfterTime;
    expect(Date.parse(after!) / 1000).toBeGreaterThanOrEqual(startS);
    expect(
      await codeOf(resetStaffPassword.run(asStaff({ uid, password: "mine-pass-3" }, uid))),
    ).toBe("NOT_ADMIN");
  });

  it("deleting needs the typed name and removes the account, its phone and its devices' access", async () => {
    const { uid } = await newStaff({ mobile: "09171234567" });
    await db.collection(C.users).doc(uid).collection(C.pushTokens).doc("fid1").set({ fid: "fid1" });
    expect(await codeOf(deleteStaff.run(asAdmin({ uid, confirmName: "Juan" })))).toBe(
      "CONFIRM_MISMATCH",
    );
    await deleteStaff.run(asAdmin({ uid, confirmName: " juan dela cruz " }));
    expect((await db.collection(C.users).doc(uid).get()).exists).toBe(false);
    expect((await db.collection(C.users).doc(uid).collection(C.pushTokens).get()).size).toBe(0);
    expect((await db.collection(C.phoneIndex).doc("639171234567").get()).exists).toBe(false);
    await expect(getAuth().getUser(uid)).rejects.toMatchObject({ code: "auth/user-not-found" });
    expect(await member(uid)).toBeNull();
  });
});

describe("admin accounts", () => {
  const tokenFrom = (text: string) => decodeURIComponent(/setup\?token=(\S+)/.exec(text)![1]!);

  // An admin as tools/seed-admins.ts makes one: the admin claim and an invited
  // record, no password yet (there are no invites on the website).
  async function seedInvited(email: string, name = email.split("@")[0]!) {
    const { uid } = await getAuth().createUser({ email, displayName: name });
    await getAuth().setCustomUserClaims(uid, { role: "admin" });
    await db.collection(C.admins).doc(uid).set({
      name,
      email,
      status: "invited",
      invitedBy: null,
      invitedAt: ts(Date.now()),
      inviteSentAt: null,
      activatedAt: null,
    });
    return uid;
  }

  it("a seeded admin sets a password once with the emailed link, then is active and a member", async () => {
    const uid = await seedInvited("ana@example.com", "Ana");
    expect(await requestAdminSetup.run(call({ email: "Ana@Example.com" }))).toEqual({ ok: true });
    const token = tokenFrom(fake.mail.at(-1)!.text);
    expect(await codeOf(listAdmins.run(asAdmin({}, uid)))).toBe("NOT_ADMIN");
    expect(await member(uid)).toBeNull();

    expect(await completeAdminSetup.run(call({ token, password: "admin-pass-1" }))).toEqual({
      email: "ana@example.com",
    });
    expect(await signsIn("ana@example.com", "admin-pass-1")).toBe(true);
    expect(await codeOf(completeAdminSetup.run(call({ token, password: "admin-pass-2" })))).toBe(
      "RESET_TOKEN_INVALID",
    );
    await syncMyAdmin.run(asAdmin({}, uid));
    expect((await db.collection(C.admins).doc(uid).get()).get("status")).toBe("active");
    expect(await member(uid)).toBe(true);
    // Active now: no more setup links.
    fake.mail = [];
    await requestAdminSetup.run(call({ email: "ana@example.com" }));
    expect(fake.mail).toHaveLength(0);
  });

  it("requestAdminSetup replies the same and sends only to invited admins", async () => {
    await seedInvited("ana@example.com");
    fake.mail = [];
    for (const email of ["ana@example.com", "dana@example.com", "nobody@example.com", "bad"]) {
      expect(await requestAdminSetup.run(call({ email }))).toEqual({ ok: true });
    }
    expect(fake.mail.map((m) => m.to)).toEqual(["ana@example.com"]);
  });

  it("an expired or replaced link no longer works", async () => {
    const uid = await seedInvited("ana@example.com");
    await requestAdminSetup.run(call({ email: "ana@example.com" }));
    const first = tokenFrom(fake.mail.at(-1)!.text);
    await requestAdminSetup.run(call({ email: "ana@example.com" }));
    const second = tokenFrom(fake.mail.at(-1)!.text);
    expect(
      await codeOf(completeAdminSetup.run(call({ token: first, password: "admin-pass-1" }))),
    ).toBe("RESET_TOKEN_INVALID");
    await db
      .collection(C.adminSetupTokens)
      .doc(uid)
      .update({ expiresAt: ts(Date.now() - 1000) });
    expect(
      await codeOf(completeAdminSetup.run(call({ token: second, password: "admin-pass-1" }))),
    ).toBe("RESET_TOKEN_INVALID");
  });

  it("removing: never yourself, never the last admin; access, membership and phone end at once", async () => {
    await getAuth().createUser({ uid: "admin1", email: "dana@example.com" });
    await getAuth().createUser({ uid: "admin2", email: "mark@example.com" });
    for (const uid of ["admin1", "admin2"]) await rtdb.ref(`members/${uid}`).set(true);
    await db
      .collection(C.admins)
      .doc("admin2")
      .set({ name: "Mark", email: "mark@example.com", status: "active", phone: "639170000008" });
    await db.collection(C.phoneIndex).doc("639170000008").set({ uid: "admin2" });
    expect(await codeOf(removeAdmin.run(asAdmin({ uid: "admin1" })))).toBe("SELF_REMOVE");

    const results = await Promise.all([
      codeOf(removeAdmin.run(asAdmin({ uid: "admin2" }, "admin1"))),
      codeOf(removeAdmin.run(asAdmin({ uid: "admin1" }, "admin2"))),
    ]);
    expect(results.filter((r) => r === "ok")).toHaveLength(1);
    const left = await db.collection(C.admins).where("status", "==", "active").get();
    expect(left.size).toBe(1);
    const removed = results[0] === "ok" ? "admin2" : "admin1";
    expect(await codeOf(listAdmins.run(asAdmin({}, removed)))).toBe("NOT_ADMIN");
    expect(await member(removed)).toBeNull();
    if (removed === "admin2") {
      expect((await db.collection(C.phoneIndex).doc("639170000008").get()).exists).toBe(false);
    }
  });

  it("an admin sets or removes their own mobile for SMS alerts; numbers stay unique", async () => {
    await updateMyAdminMobile.run(asAdmin({ mobile: "0917 000 0009" }));
    expect((await db.collection(C.admins).doc("admin1").get()).get("phone")).toBe("639170000009");
    expect((await db.collection(C.phoneIndex).doc("639170000009").get()).get("uid")).toBe("admin1");
    await newStaff({ username: "juan", mobile: "09171234567" });
    expect(await codeOf(updateMyAdminMobile.run(asAdmin({ mobile: "09171234567" })))).toBe(
      "PHONE_IN_USE",
    );
    await updateMyAdminMobile.run(asAdmin({ mobile: null }));
    expect((await db.collection(C.admins).doc("admin1").get()).get("phone")).toBeNull();
    expect((await db.collection(C.phoneIndex).doc("639170000009").get()).exists).toBe(false);
  });

  it("lists admins with status, phone and the below-2 hint; renames; email follows Auth", async () => {
    await getAuth().createUser({ uid: "admin1", email: "dana@example.com" });
    const first = await listAdmins.run(asAdmin({}));
    expect(first.belowRecommended).toBe(true);
    expect(first.admins).toMatchObject([
      { uid: "admin1", you: true, status: "active", phone: null },
    ]);

    await updateMyAdminName.run(asAdmin({ name: "Dana Perez" }));
    await getAuth().updateUser("admin1", { email: "dana.p@example.com", emailVerified: true });
    await syncMyAdmin.run(asAdmin({}));
    expect((await db.collection(C.admins).doc("admin1").get()).data()).toMatchObject({
      name: "Dana Perez",
      email: "dana.p@example.com",
    });
    expect(await codeOf(listAdmins.run(asAdmin({})))).toBe("ok");
  });

  it("signOutEverywhere revokes every session of the caller", async () => {
    await getAuth().createUser({ uid: "admin1", email: "dana@example.com" });
    const startS = Math.floor(Date.now() / 1000);
    await signOutEverywhere.run(asAdmin({}));
    const after = (await getAuth().getUser("admin1")).tokensValidAfterTime;
    expect(Date.parse(after!) / 1000).toBeGreaterThanOrEqual(startS);
  });
});
