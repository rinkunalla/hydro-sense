// Staff accounts (D64). Only an admin creates, edits, resets, disables or
// deletes them; staff change nothing about their own account. A staff member
// signs in with a username: Firebase Auth holds it as a hidden address
// (staffLoginEmail), so Auth itself keeps usernames unique. Mobile numbers stay
// unique through phone_index (shared with admins). Internally a staff account
// has role "user".
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/https";
import { requireAdmin } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { setMember } from "../lib/members";
import {
  confirmMatches,
  parseName,
  parseOptionalEmail,
  parseOptionalPhone,
  parsePassword,
  parseUid,
  parseUsername,
  staffLoginEmail,
} from "../lib/userInput";

const fail = (
  status: "already-exists" | "not-found" | "invalid-argument" | "failed-precondition",
  code: string,
  message: string,
) => new HttpsError(status, message, { code });

const usernameTaken = () =>
  fail("already-exists", "USERNAME_IN_USE", "Another account already uses this username.");
export const phoneTaken = () =>
  fail("already-exists", "PHONE_IN_USE", "Another account already uses this mobile number.");

const isEmailTaken = (e: unknown) => (e as { code?: string }).code === "auth/email-already-exists";

async function loadStaff(uid: string) {
  const snap = await db.collection(C.users).doc(uid).get();
  if (!snap.exists || snap.get("role") !== "user") {
    throw fail("not-found", "USER_NOT_FOUND", "Staff member not found.");
  }
  return snap;
}

/**
 * Moves an account's mobile number in phone_index (inside a transaction):
 * refuses a number another account holds and frees the old one. Shared by
 * staff and admins.
 */
export async function movePhone(
  tx: FirebaseFirestore.Transaction,
  uid: string,
  from: string | null,
  to: string | null,
): Promise<void> {
  if (to === from) return;
  if (to !== null) {
    const holder = (await tx.get(db.collection(C.phoneIndex).doc(to))).get("uid") as
      string | undefined;
    if (holder && holder !== uid) throw phoneTaken();
  }
  if (from) tx.delete(db.collection(C.phoneIndex).doc(from));
  if (to !== null) tx.set(db.collection(C.phoneIndex).doc(to), { uid });
}

/** Fast pre-check before Auth changes; movePhone in the transaction is the real guard. */
export async function assertPhoneFree(uid: string, phone: string | null | undefined) {
  if (!phone) return;
  const holder = (await db.collection(C.phoneIndex).doc(phone).get()).get("uid");
  if (holder && holder !== uid) throw phoneTaken();
}

/** The Staff page: everything the table and side panel show. */
export const adminListStaff = onCall(async (request) => {
  await requireAdmin(request);
  const snap = await db.collection(C.users).where("role", "==", "user").get();
  const auth = snap.empty
    ? { users: [] }
    : await getAuth().getUsers(snap.docs.map((d) => ({ uid: d.id })));
  const lastSignIn = new Map(
    auth.users.map((u) => [
      u.uid,
      u.metadata.lastSignInTime ? Date.parse(u.metadata.lastSignInTime) : null,
    ]),
  );
  return {
    staff: snap.docs.map((d) => ({
      uid: d.id,
      name: (d.get("name") as string | undefined) ?? "",
      username: (d.get("username") as string | undefined) ?? "",
      email: (d.get("email") as string | null | undefined) ?? null,
      phone: (d.get("phone") as string | null | undefined) ?? null,
      status: d.get("status") === "disabled" ? "disabled" : "active",
      createdAtMs: ms(d.get("createdAt")),
      lastSignInMs: lastSignIn.get(d.id) ?? null,
    })),
  };
});

/** {name, username, password, mobile?, email?} */
export const createStaff = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const name = parseName(d.name);
  const username = parseUsername(d.username);
  const password = parsePassword(d.password);
  const phone = parseOptionalPhone(d.mobile) ?? null;
  const email = parseOptionalEmail(d.email) ?? null;

  await assertPhoneFree("", phone);
  const auth = getAuth();
  let uid: string;
  try {
    uid = (await auth.createUser({ email: staffLoginEmail(username), password, displayName: name }))
      .uid;
  } catch (e) {
    if (isEmailTaken(e)) throw usernameTaken();
    throw e;
  }
  try {
    await db.runTransaction(async (tx) => {
      await movePhone(tx, uid, null, phone);
      tx.create(db.collection(C.users).doc(uid), {
        role: "user",
        name,
        username,
        email,
        phone,
        status: "active",
        createdAt: ts(Date.now()),
      });
    });
    await auth.setCustomUserClaims(uid, { role: "user" });
    await setMember(uid, true);
  } catch (e) {
    await auth.deleteUser(uid).catch(() => undefined);
    throw e;
  }
  return { uid };
});

/**
 * {uid, name?, username?, mobile?, email?, disabled?}. mobile or email null
 * (or "") removes that contact, which stops that alert channel (D65).
 * Disabling ends the sessions and refuses sign-in; enabling undoes it.
 */
export const updateStaff = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const uid = parseUid(d.uid);
  const staff = await loadStaff(uid);
  const name = d.name === undefined ? undefined : parseName(d.name);
  const username = d.username === undefined ? undefined : parseUsername(d.username);
  const phone = parseOptionalPhone(d.mobile);
  const email = parseOptionalEmail(d.email);
  if (d.disabled !== undefined && typeof d.disabled !== "boolean") {
    throw fail("invalid-argument", "PAYLOAD_INVALID", "disabled must be true or false.");
  }
  const disabled = d.disabled as boolean | undefined;
  const oldPhone = (staff.get("phone") as string | null | undefined) ?? null;

  await assertPhoneFree(uid, phone);
  const authChanges = {
    ...(username !== undefined && username !== staff.get("username")
      ? { email: staffLoginEmail(username) }
      : {}),
    ...(name !== undefined ? { displayName: name } : {}),
    ...(disabled !== undefined ? { disabled } : {}),
  };
  if (Object.keys(authChanges).length > 0) {
    try {
      await getAuth().updateUser(uid, authChanges);
    } catch (e) {
      if (isEmailTaken(e)) throw usernameTaken();
      throw e;
    }
  }
  if (disabled === true) await getAuth().revokeRefreshTokens(uid);

  await db.runTransaction(async (tx) => {
    if (phone !== undefined) await movePhone(tx, uid, oldPhone, phone);
    tx.update(staff.ref, {
      ...(name !== undefined ? { name } : {}),
      ...(username !== undefined ? { username } : {}),
      ...(phone !== undefined ? { phone } : {}),
      ...(email !== undefined ? { email } : {}),
      ...(disabled !== undefined ? { status: disabled ? "disabled" : "active" } : {}),
    });
  });
  if (disabled !== undefined) await setMember(uid, !disabled);
  return { uid };
});

/** {uid, password}: the admin sets a new password; every old session ends. */
export const resetStaffPassword = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const uid = parseUid(d.uid);
  const password = parsePassword(d.password);
  await loadStaff(uid);
  await getAuth().updateUser(uid, { password });
  await getAuth().revokeRefreshTokens(uid);
  return { uid };
});

/** {uid, confirmName}: deletes the account at once (D66: no restore window). */
export const deleteStaff = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const uid = parseUid(d.uid);
  const staff = await loadStaff(uid);
  if (!confirmMatches(d.confirmName, staff.get("name") as string)) {
    throw fail("invalid-argument", "CONFIRM_MISMATCH", "The typed name does not match.");
  }
  await setMember(uid, false);
  await getAuth()
    .deleteUser(uid)
    .catch((e: { code?: string }) => {
      if (e.code !== "auth/user-not-found") throw e;
    });
  const phone = staff.get("phone") as string | null | undefined;
  await db.recursiveDelete(staff.ref); // includes push_tokens
  if (phone) await db.collection(C.phoneIndex).doc(phone).delete();
  return { uid };
});
