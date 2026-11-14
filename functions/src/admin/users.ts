// Admin user management (CLAUDE.md section 6, D20, D22, D31, D42). Users are
// created without a usable password; they set one by SMS code (stage 3).
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/https";
import { RESTORE_WINDOW_DAYS } from "../config";
import { requireAdmin } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { MAIL_SECRETS } from "../lib/providers";
import { confirmMatches, parseEmail, parseName, parsePhone, parseUid } from "../lib/userInput";
import { audit } from "./audit";

const DAY_MS = 86_400_000;

export const DEFAULT_ALERT_PREFS = { push: true, sms: true, email: false } as const;

const inUse = (code: "EMAIL_IN_USE" | "PHONE_IN_USE") =>
  new HttpsError(
    "already-exists",
    code === "EMAIL_IN_USE"
      ? "Another account already uses this email."
      : "Another account already uses this mobile number.",
    { code },
  );

const isEmailTaken = (e: unknown) => (e as { code?: string }).code === "auth/email-already-exists";

async function loadUser(uid: string) {
  const snap = await db.collection(C.users).doc(uid).get();
  if (!snap.exists || snap.get("role") !== "user") {
    throw new HttpsError("not-found", "User not found.", { code: "USER_NOT_FOUND" });
  }
  return snap;
}

export const createUser = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const name = parseName(d.name);
  const email = parseEmail(d.email);
  const phone = parsePhone(d.mobile);

  const phoneRef = db.collection(C.phoneIndex).doc(phone);
  if ((await phoneRef.get()).exists) throw inUse("PHONE_IN_USE");

  const auth = getAuth();
  let uid: string;
  try {
    uid = (await auth.createUser({ email, displayName: name })).uid;
  } catch (e) {
    if (isEmailTaken(e)) throw inUse("EMAIL_IN_USE");
    throw e;
  }

  try {
    // The pre-check above is only a fast path; this transaction is the real guard.
    await db.runTransaction(async (tx) => {
      if ((await tx.get(phoneRef)).exists) throw inUse("PHONE_IN_USE");
      tx.create(phoneRef, { uid });
      tx.create(db.collection(C.users).doc(uid), {
        role: "user",
        name,
        email,
        phone,
        passwordSet: false,
        deviceCount: 0,
        alertPrefs: DEFAULT_ALERT_PREFS,
        status: "active",
        suspendedAt: null,
        purgeAfter: null,
        deletionRequestedAt: null,
        createdAt: ts(Date.now()),
      });
    });
    await auth.setCustomUserClaims(uid, { role: "user" });
  } catch (e) {
    await auth.deleteUser(uid).catch(() => undefined);
    throw e;
  }
  return { uid };
});

export const updateUser = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const uid = parseUid(d.uid);
  const user = await loadUser(uid);
  const name = d.name === undefined ? undefined : parseName(d.name);
  const email = d.email === undefined ? undefined : parseEmail(d.email);
  const phone = d.mobile === undefined ? undefined : parsePhone(d.mobile);
  const oldPhone = user.get("phone") as string;
  const phoneChanges = phone !== undefined && phone !== oldPhone;

  if (phoneChanges) {
    const owner = (await db.collection(C.phoneIndex).doc(phone).get()).get("uid");
    if (owner && owner !== uid) throw inUse("PHONE_IN_USE");
  }
  const authChanges = {
    ...(email !== undefined && email !== user.get("email") ? { email } : {}),
    ...(name !== undefined ? { displayName: name } : {}),
  };
  if (Object.keys(authChanges).length > 0) {
    try {
      await getAuth().updateUser(uid, authChanges);
    } catch (e) {
      if (isEmailTaken(e)) throw inUse("EMAIL_IN_USE");
      throw e;
    }
  }

  await db.runTransaction(async (tx) => {
    const userRef = db.collection(C.users).doc(uid);
    if (phoneChanges) {
      const newRef = db.collection(C.phoneIndex).doc(phone);
      const owner = (await tx.get(newRef)).get("uid");
      if (owner && owner !== uid) throw inUse("PHONE_IN_USE");
      tx.delete(db.collection(C.phoneIndex).doc(oldPhone));
      tx.set(newRef, { uid });
    }
    tx.update(userRef, {
      ...(name !== undefined ? { name } : {}),
      ...(email !== undefined ? { email } : {}),
      ...(phoneChanges ? { phone } : {}),
    });
  });
  return { uid };
});

/** Suspends the account (D42): sign-in refused, no alerts, data and devices kept. */
export const deleteUser = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const adminUid = await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const uid = parseUid(d.uid);
  const user = await loadUser(uid);
  const name = user.get("name") as string;
  if (!confirmMatches(d.confirmName, name)) {
    throw new HttpsError("invalid-argument", "The typed name does not match.", {
      code: "CONFIRM_MISMATCH",
    });
  }
  if (user.get("status") === "suspended") {
    throw new HttpsError("failed-precondition", "This user is already deleted.", {
      code: "ALREADY_SUSPENDED",
    });
  }
  const nowMs = Date.now();
  await getAuth().updateUser(uid, { disabled: true });
  await getAuth().revokeRefreshTokens(uid);
  const purgeAfterMs = nowMs + RESTORE_WINDOW_DAYS * DAY_MS;
  await user.ref.update({
    status: "suspended",
    suspendedAt: ts(nowMs),
    purgeAfter: ts(purgeAfterMs),
  });
  await audit({ adminUid, action: "user_deleted", targetId: uid, targetName: name, nowMs });
  return { uid, purgeAfterMs };
});

export const restoreUser = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const adminUid = await requireAdmin(request);
  const uid = parseUid((request.data as { uid?: unknown } | null)?.uid);
  const user = await loadUser(uid);
  const purgeAfterMs = ms(user.get("purgeAfter"));
  const nowMs = Date.now();
  if (user.get("status") !== "suspended") {
    throw new HttpsError("failed-precondition", "This user is not deleted.", {
      code: "NOT_SUSPENDED",
    });
  }
  if (purgeAfterMs === null || purgeAfterMs <= nowMs) {
    throw new HttpsError("failed-precondition", "The 30 days to restore have passed.", {
      code: "RESTORE_EXPIRED",
    });
  }
  await getAuth().updateUser(uid, { disabled: false });
  await user.ref.update({ status: "active", suspendedAt: null, purgeAfter: null });
  const name = user.get("name") as string;
  await audit({ adminUid, action: "user_restored", targetId: uid, targetName: name, nowMs });
  return { uid };
});
