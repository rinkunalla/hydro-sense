// Stage 3 acceptance tests (KICKOFF.md): SMS codes, user self-service and admin
// accounts. In-process against the Auth and Firestore emulators, with fake SMS,
// OTP and email providers. Run WITHOUT the Functions emulator (test:inprocess).
import { getAuth } from "firebase-admin/auth";
import type { CallableRequest } from "firebase-functions/https";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import {
  cancelAdminInvite,
  completeAdminSetup,
  inviteAdmin,
  listAdmins,
  removeAdmin,
  requestAdminSetup,
  resendAdminInvite,
  signOutEverywhere,
  syncMyAdmin,
  updateMyAdminName,
} from "../src/admin/admins";
import { createUser, deleteUser } from "../src/admin/users";
import { listDevicesForAdmin } from "../src/admin/devices";
import { runAlertPass } from "../src/alerts/alertPass";
import { requestResetCode, setPasswordWithResetToken, verifyResetCode } from "../src/auth/reset";
import {
  confirmPhoneChange,
  requestAccountDeletion,
  requestPhoneChangeCode,
  syncMyEmail,
  updateMyName,
} from "../src/auth/self";
import { C, db, ts } from "../src/lib/db";
import { setProviders, type Providers } from "../src/lib/providers";
import { manilaDateKey } from "../src/lib/time";

const PROJECT = process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836";
const FIRESTORE = process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080";
const AUTH = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099";
const MIN = 60_000;
const PHONE = "639171234567";
const MOBILE = "0917 123 4567";
const UNKNOWN = "0917 000 0000";

class Fake implements Providers {
  sent: { to: string; message: string; code: string }[] = [];
  mail: { to: string; subject: string; text: string }[] = [];
  smsSent: string[] = [];
  otpFail = false;
  sms = { send: async (to: string) => void this.smsSent.push(to) };
  email = {
    send: async (to: string, subject: string, text: string) =>
      void this.mail.push({ to, subject, text }),
  };
  push = { send: async (fids: string[]) => ({ sent: fids.length, stale: [] as string[] }) };
  otp = {
    send: async (to: string, message: string, code: string) => {
      if (this.otpFail) throw new Error("Semaphore OTP HTTP 500");
      this.sent.push({ to, message, code });
      return code;
    },
  };
}

let fake: Fake;

const call = <T>(data: T, auth?: { uid: string; token: Record<string, unknown> }) =>
  ({ data, ...(auth ? { auth } : {}) }) as unknown as CallableRequest<T>;
const asAdmin = <T>(data: T, uid = "admin1") => call(data, { uid, token: { role: "admin" } });
const asUser = <T>(data: T, uid: string, authTimeS = Math.floor(Date.now() / 1000)) =>
  call(data, { uid, token: { role: "user", auth_time: authTimeS } });
const lastCode = () => fake.sent.at(-1)!.code;

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

async function newUser(mobile = MOBILE, email = "juan@example.com") {
  return (await createUser.run(asAdmin({ name: "Juan", email, mobile }))).uid;
}

const codeOf = async (p: Promise<unknown>) =>
  p.then(
    () => "ok",
    (e: { details?: { code?: string; triesLeft?: number } }) =>
      `${e.details?.code}${e.details?.triesLeft === undefined ? "" : `:${e.details.triesLeft}`}`,
  );

beforeEach(async () => {
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

describe("reset by SMS code (D22)", () => {
  it("replies the same for a known and an unknown number, and stores only a hash", async () => {
    const uid = await newUser();
    const known = await requestResetCode.run(call({ mobile: MOBILE }));
    const unknown = await requestResetCode.run(call({ mobile: UNKNOWN }));
    expect(known).toEqual({ ok: true, resendAfterSeconds: 60 });
    expect(unknown).toEqual(known);
    expect(fake.sent.map((s) => s.to)).toEqual([PHONE]);
    expect(fake.sent[0]!.message).toBe(
      "Hydro Sense: your code is {otp}. It expires in 5 minutes. Never share this code.",
    );
    expect(lastCode()).toMatch(/^\d{6}$/);

    const doc = JSON.stringify((await db.collection(C.passwordResets).doc(uid).get()).data());
    expect(doc).not.toContain(lastCode());
    // The resend gap applies to both numbers alike.
    expect(await codeOf(requestResetCode.run(call({ mobile: MOBILE })))).toBe("COOLDOWN");
    expect(await codeOf(requestResetCode.run(call({ mobile: UNKNOWN })))).toBe("COOLDOWN");
  });

  it("sets the password with a code and a one-time token", async () => {
    const uid = await newUser();
    await requestResetCode.run(call({ mobile: MOBILE }));
    const { resetToken } = await verifyResetCode.run(call({ mobile: MOBILE, code: lastCode() }));
    expect(
      await codeOf(setPasswordWithResetToken.run(call({ resetToken, newPassword: "short" }))),
    ).toBe("PASSWORD_WEAK");

    const r = await setPasswordWithResetToken.run(
      call({ resetToken, newPassword: "new-secret-1" }),
    );
    expect(r).toEqual({ email: "juan@example.com" });
    expect(await signsIn("juan@example.com", "new-secret-1")).toBe(true);
    expect((await db.collection(C.users).doc(uid).get()).get("passwordSet")).toBe(true);
    expect(
      await codeOf(setPasswordWithResetToken.run(call({ resetToken, newPassword: "again-123" }))),
    ).toBe("RESET_TOKEN_INVALID");
    expect(await codeOf(verifyResetCode.run(call({ mobile: MOBILE, code: lastCode() })))).toMatch(
      /^RESET_CODE_/,
    );
  });

  it("counts wrong codes, locks after 5, and an unknown number behaves the same", async () => {
    await newUser();
    await requestResetCode.run(call({ mobile: MOBILE }));
    await requestResetCode.run(call({ mobile: UNKNOWN }));
    const wrong = lastCode() === "000000" ? "111111" : "000000";
    for (const mobile of [MOBILE, UNKNOWN]) {
      const seen: string[] = [];
      for (let i = 0; i < 6; i++) {
        seen.push(await codeOf(verifyResetCode.run(call({ mobile, code: wrong }))));
      }
      expect(seen).toEqual([
        "RESET_CODE_INVALID:4",
        "RESET_CODE_INVALID:3",
        "RESET_CODE_INVALID:2",
        "RESET_CODE_INVALID:1",
        "RESET_CODE_INVALID:0",
        "RESET_LOCKED",
      ]);
    }
    // Even the right code is refused once locked.
    expect(await codeOf(verifyResetCode.run(call({ mobile: MOBILE, code: lastCode() })))).toBe(
      "RESET_LOCKED",
    );
  });

  it("expires a code after 5 minutes", async () => {
    const uid = await newUser();
    await requestResetCode.run(call({ mobile: MOBILE }));
    await db
      .collection(C.passwordResets)
      .doc(uid)
      .update({ expiresAt: ts(Date.now() - 1000) });
    expect(await codeOf(verifyResetCode.run(call({ mobile: MOBILE, code: lastCode() })))).toBe(
      "RESET_CODE_EXPIRED",
    );
  });

  it("an unknown number's code also expires after 5 minutes (no timing tell)", async () => {
    const uid = await newUser();
    await requestResetCode.run(call({ mobile: MOBILE }));
    await requestResetCode.run(call({ mobile: UNKNOWN }));
    const past = ts(Date.now() - 6 * MIN);
    await db
      .collection(C.passwordResets)
      .doc(uid)
      .update({ expiresAt: ts(Date.now() - MIN) });
    await db
      .collection(C.rateLimits)
      .doc(`otp__639170000000__${manilaDateKey(Date.now())}`)
      .update({ lastSentAt: past });
    for (const mobile of [MOBILE, UNKNOWN]) {
      expect(await codeOf(verifyResetCode.run(call({ mobile, code: "123456" })))).toBe(
        "RESET_CODE_EXPIRED",
      );
    }
  });

  it("holds the resend gap under 10 parallel requests (one SMS)", async () => {
    await newUser();
    const replies = await Promise.all(
      Array.from({ length: 10 }, () => codeOf(requestResetCode.run(call({ mobile: MOBILE })))),
    );
    expect(replies.filter((r) => r === "ok")).toHaveLength(1);
    expect(fake.sent).toHaveLength(1);
  });

  it("stops at 5 codes per phone per day and 30 per project per day", async () => {
    await newUser();
    const day = `otp__${PHONE}__${manilaDateKey(Date.now())}`;
    await db.collection(C.rateLimits).doc(day).set({ count: 5 });
    expect(await codeOf(requestResetCode.run(call({ mobile: MOBILE })))).toBe("DAILY_LIMIT");

    await db.collection(C.rateLimits).doc(day).delete();
    await db.collection(C.alertDaily).doc(manilaDateKey(Date.now())).set({ otpCount: 30 });
    expect(await codeOf(requestResetCode.run(call({ mobile: MOBILE })))).toBe("DAILY_LIMIT");
    expect(fake.sent).toHaveLength(0);
    const logs = await db
      .collection(C.errorLogs)
      .where("code", "==", "OTP_PROJECT_CAP_REACHED")
      .get();
    expect(logs.size).toBe(1);
  });

  it("sends nothing to a suspended account but replies the same", async () => {
    const uid = await newUser();
    await deleteUser.run(asAdmin({ uid, confirmName: "Juan" }));
    expect(await requestResetCode.run(call({ mobile: MOBILE }))).toEqual({
      ok: true,
      resendAfterSeconds: 60,
    });
    expect(fake.sent).toHaveLength(0);
  });

  it("replies the same when Semaphore fails, and logs OTP_FAILED", async () => {
    await newUser();
    fake.otpFail = true;
    expect(await requestResetCode.run(call({ mobile: MOBILE }))).toEqual({
      ok: true,
      resendAfterSeconds: 60,
    });
    const logs = await db.collection(C.errorLogs).where("code", "==", "OTP_FAILED").get();
    expect(logs.size).toBe(1);
  });
});

describe("user self-service (D31, D42)", () => {
  it("changes the mobile: code only to the new number, then alerts go there", async () => {
    const uid = await newUser();
    await newUser("0918 000 0001", "other@example.com");
    const old = Math.floor(Date.now() / 1000) - 600;
    expect(
      await codeOf(requestPhoneChangeCode.run(asUser({ newMobile: "0918 222 2210" }, uid, old))),
    ).toBe("REAUTH_REQUIRED");
    expect(
      await codeOf(requestPhoneChangeCode.run(asUser({ newMobile: "0918 000 0001" }, uid))),
    ).toBe("PHONE_IN_USE");

    const r = await requestPhoneChangeCode.run(asUser({ newMobile: "0918 222 2210" }, uid));
    expect(r).toMatchObject({ ok: true, sentTo: "0918 ••• 2210" });
    expect(fake.sent.map((s) => s.to)).toEqual(["639182222210"]);

    await confirmPhoneChange.run(asUser({ code: lastCode() }, uid));
    const user = (await db.collection(C.users).doc(uid).get()).data()!;
    expect(user.phone).toBe("639182222210");
    expect((await db.collection(C.phoneIndex).doc(PHONE).get()).exists).toBe(false);
    expect((await db.collection(C.phoneIndex).doc("639182222210").get()).get("uid")).toBe(uid);
    expect(fake.mail.at(-1)).toMatchObject({
      to: "juan@example.com",
      subject: "Your Hydro Sense mobile number was changed",
    });

    await db
      .collection(C.devices)
      .doc("D1")
      .set({
        ownerUid: uid,
        nickname: "Garden Line",
        flowStatus: "No Flow",
        abnormalSince: ts(Date.now() - 2 * MIN),
      });
    await db
      .collection(C.deviceHealth)
      .doc("D1")
      .set({ ownerUid: uid, online: true, lastSeen: ts(Date.now()) });
    await runAlertPass();
    expect(fake.smsSent).toEqual(["639182222210"]);
  });

  it("a reset code cannot confirm a mobile change", async () => {
    const uid = await newUser();
    await requestResetCode.run(call({ mobile: MOBILE }));
    expect(await codeOf(confirmPhoneChange.run(asUser({ code: lastCode() }, uid)))).toMatch(
      /^RESET_CODE_INVALID/,
    );
  });

  it("updates the name and copies a verified email from Auth", async () => {
    const uid = await newUser();
    await updateMyName.run(asUser({ name: "Juan D." }, uid));
    expect((await getAuth().getUser(uid)).displayName).toBe("Juan D.");
    await getAuth().updateUser(uid, { email: "New@Example.com", emailVerified: true });
    await syncMyEmail.run(asUser({}, uid));
    expect((await db.collection(C.users).doc(uid).get()).data()).toMatchObject({
      name: "Juan D.",
      email: "new@example.com",
    });
  });

  it("asking for deletion logs it and emails the admins, once", async () => {
    const uid = await newUser();
    expect(await requestAccountDeletion.run(asUser({}, uid))).toEqual({ alreadyRequested: false });
    expect(await requestAccountDeletion.run(asUser({}, uid))).toEqual({ alreadyRequested: true });
    const log = (await db.collection(C.adminAudit).get()).docs.map((d) => d.data());
    expect(log).toMatchObject([
      { action: "deletion_requested", adminUid: uid, targetName: "Juan" },
    ]);
    expect(fake.mail.map((m) => m.subject)).toEqual([
      "Hydro Sense: Juan asked to delete their account",
    ]);
  });

  it("a suspended user's callables are refused at once", async () => {
    const uid = await newUser();
    await deleteUser.run(asAdmin({ uid, confirmName: "Juan" }));
    expect(await codeOf(updateMyName.run(asUser({ name: "x" }, uid)))).toBe("NOT_USER");
  });
});

describe("admin accounts (D23, D40)", () => {
  const tokenFrom = (text: string) => decodeURIComponent(/setup\?token=(\S+)/.exec(text)![1]!);

  it("invites an admin who sets a password once, then becomes active on sign-in", async () => {
    const { uid, link } = await inviteAdmin.run(asAdmin({ email: "Ana@Example.com", name: "Ana" }));
    expect(link).toBe("sent");
    expect((await db.collection(C.admins).doc(uid).get()).data()).toMatchObject({
      email: "ana@example.com",
      status: "invited",
      invitedBy: "admin1",
    });
    expect((await getAuth().getUser(uid)).customClaims).toEqual({ role: "admin" });
    const token = tokenFrom(fake.mail.at(-1)!.text);
    expect(fake.mail.at(-1)!.subject).toBe("Set up your Hydro Sense admin account");
    expect(
      JSON.stringify((await db.collection(C.adminSetupTokens).doc(uid).get()).data()),
    ).not.toContain(token.split(".")[1]);

    // Invited admins are not admins yet.
    expect(await codeOf(listAdmins.run(asAdmin({}, uid)))).toBe("NOT_ADMIN");

    expect(await completeAdminSetup.run(call({ token, password: "admin-pass-1" }))).toEqual({
      email: "ana@example.com",
    });
    expect(await signsIn("ana@example.com", "admin-pass-1")).toBe(true);
    expect(await codeOf(completeAdminSetup.run(call({ token, password: "admin-pass-2" })))).toBe(
      "RESET_TOKEN_INVALID",
    );

    await syncMyAdmin.run(asAdmin({}, uid));
    expect((await db.collection(C.admins).doc(uid).get()).get("status")).toBe("active");
    expect(await codeOf(resendAdminInvite.run(asAdmin({ uid })))).toBe("INVITE_NOT_PENDING");
  });

  it("requestAdminSetup replies the same and sends only to invited admins", async () => {
    await inviteAdmin.run(asAdmin({ email: "ana@example.com" }));
    fake.mail = [];
    for (const email of ["ana@example.com", "dana@example.com", "nobody@example.com", "bad"]) {
      expect(await requestAdminSetup.run(call({ email }))).toEqual({ ok: true });
    }
    expect(fake.mail.map((m) => m.to)).toEqual(["ana@example.com"]);
  });

  it("an expired or replaced link no longer works", async () => {
    const { uid } = await inviteAdmin.run(asAdmin({ email: "ana@example.com" }));
    const first = tokenFrom(fake.mail.at(-1)!.text);
    await resendAdminInvite.run(asAdmin({ uid }));
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
    const { admins } = await listAdmins.run(asAdmin({}));
    expect(admins.find((a) => a.uid === uid)).toMatchObject({ status: "invited" });
  });

  it("cancelling an invite deletes the Auth user and the record", async () => {
    const { uid } = await inviteAdmin.run(asAdmin({ email: "ana@example.com" }));
    await getAuth().createUser({ uid: "admin1", email: "dana@example.com" });
    await cancelAdminInvite.run(asAdmin({ uid }));
    expect((await db.collection(C.admins).doc(uid).get()).exists).toBe(false);
    await expect(getAuth().getUser(uid)).rejects.toMatchObject({ code: "auth/user-not-found" });
    expect(await codeOf(inviteAdmin.run(asAdmin({ email: "dana@example.com" })))).toBe(
      "EMAIL_IN_USE",
    );
  });

  it("removing: never yourself, never the last admin, and access ends at once", async () => {
    await getAuth().createUser({ uid: "admin1", email: "dana@example.com" });
    await getAuth().createUser({ uid: "admin2", email: "mark@example.com" });
    await db
      .collection(C.admins)
      .doc("admin2")
      .set({ name: "Mark", email: "mark@example.com", status: "active" });
    expect(await codeOf(removeAdmin.run(asAdmin({ uid: "admin1" })))).toBe("SELF_REMOVE");

    // Both remove each other at once: one wins, one admin is always left.
    const results = await Promise.all([
      codeOf(removeAdmin.run(asAdmin({ uid: "admin2" }, "admin1"))),
      codeOf(removeAdmin.run(asAdmin({ uid: "admin1" }, "admin2"))),
    ]);
    expect(results.filter((r) => r === "ok")).toHaveLength(1);
    const left = await db.collection(C.admins).where("status", "==", "active").get();
    expect(left.size).toBe(1);

    const removed = results[0] === "ok" ? "admin2" : "admin1";
    expect(await codeOf(listAdmins.run(asAdmin({}, removed)))).toBe("NOT_ADMIN");
    const actions = (await db.collection(C.adminAudit).get()).docs.map((d) => d.get("action"));
    expect(actions).toEqual(["admin_removed"]);
  });

  it("lists admins with status and the below-2 hint; renames; email follows Auth", async () => {
    await getAuth().createUser({ uid: "admin1", email: "dana@example.com" });
    const first = await listAdmins.run(asAdmin({}));
    expect(first.belowRecommended).toBe(true);
    expect(first.admins).toMatchObject([{ uid: "admin1", you: true, status: "active" }]);

    await updateMyAdminName.run(asAdmin({ name: "Dana Perez" }));
    await getAuth().updateUser("admin1", { email: "dana.p@example.com", emailVerified: true });
    await syncMyAdmin.run(asAdmin({}));
    expect((await db.collection(C.admins).doc("admin1").get()).data()).toMatchObject({
      name: "Dana Perez",
      email: "dana.p@example.com",
    });
    // Keyed by uid, so the changed email keeps admin access.
    expect(await codeOf(listAdmins.run(asAdmin({})))).toBe("ok");
  });

  it("signOutEverywhere revokes every session of the caller", async () => {
    await getAuth().createUser({ uid: "admin1", email: "dana@example.com" });
    const startS = Math.floor(Date.now() / 1000);
    await signOutEverywhere.run(asAdmin({}));
    const after = (await getAuth().getUser("admin1")).tokensValidAfterTime;
    // Tokens issued before this time are now rejected (verifyIdToken with checkRevoked).
    expect(Date.parse(after!) / 1000).toBeGreaterThanOrEqual(startS);
  });

  it("admins still see devices only through the D24 list", async () => {
    expect(await listDevicesForAdmin()).toEqual([]);
  });
});
