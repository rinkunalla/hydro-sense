// Users manage their own profile. Email and password change
// in the app through Firebase Auth; these callables keep users/{uid} in step.
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/https";
import { C, db, ts } from "../lib/db";
import { requireUser, secondsSinceSignIn } from "../lib/auth";
import { logError } from "../lib/logError";
import { maskPhone } from "../lib/otp";
import { MAIL_SECRETS, OTP_SECRETS, providers } from "../lib/providers";
import { formatManila } from "../lib/time";
import { parseName, parsePhone } from "../lib/userInput";
import { audit } from "../admin/audit";
import { checkCode, sendCode } from "./codes";

/** The app re-authenticates before a mobile change; older sign-ins are refused. */
const PHONE_CHANGE_REAUTH_S = 300;

const phoneInUse = () =>
  new HttpsError("already-exists", "Another account already uses this number.", {
    code: "PHONE_IN_USE",
  });

export const updateMyName = onCall(async (request) => {
  const uid = await requireUser(request);
  const name = parseName((request.data as { name?: unknown } | null)?.name);
  await db.collection(C.users).doc(uid).update({ name });
  await getAuth().updateUser(uid, { displayName: name });
  return { name };
});

export const requestPhoneChangeCode = onCall({ secrets: OTP_SECRETS }, async (request) => {
  const uid = await requireUser(request);
  if (secondsSinceSignIn(request) > PHONE_CHANGE_REAUTH_S) {
    throw new HttpsError("failed-precondition", "Enter your current password again.", {
      code: "REAUTH_REQUIRED",
    });
  }
  const newPhone = parsePhone((request.data as { newMobile?: unknown } | null)?.newMobile);
  if ((await db.collection(C.phoneIndex).doc(newPhone).get()).exists) throw phoneInUse();
  // The code goes to the NEW number: it proves the user holds that phone.
  const resendAfterSeconds = await sendCode({
    phone: newPhone,
    uid,
    purpose: "phone_change",
    newPhone,
  });
  return { ok: true, resendAfterSeconds, sentTo: maskPhone(newPhone) };
});

export const confirmPhoneChange = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const uid = await requireUser(request);
  const userRef = db.collection(C.users).doc(uid);
  const pending = (await db.collection(C.passwordResets).doc(uid).get()).get("newPhone") as
    string | null | undefined;
  if (!pending) {
    throw new HttpsError("invalid-argument", "That code is not right.", {
      code: "RESET_CODE_INVALID",
      triesLeft: 0,
    });
  }

  // The code is used up first; the number's uniqueness is then checked again in
  // its own transaction, because another account may have taken it meanwhile.
  await checkCode(
    pending,
    uid,
    "phone_change",
    (request.data as { code?: unknown })?.code,
    (tx, doc) => tx.delete(doc.ref),
  );

  let taken = false;

  await db.runTransaction(async (tx) => {
    const [user, idx] = await Promise.all([
      tx.get(userRef),
      tx.get(db.collection(C.phoneIndex).doc(pending)),
    ]);
    if (idx.exists && idx.get("uid") !== uid) {
      taken = true;
      return;
    }
    const oldPhone = (user.get("phone") as string | undefined) ?? null;
    if (oldPhone && oldPhone !== pending) tx.delete(db.collection(C.phoneIndex).doc(oldPhone));
    tx.set(db.collection(C.phoneIndex).doc(pending), { uid });
    tx.update(userRef, { phone: pending });
  });
  if (taken) throw phoneInUse();

  const email = (await userRef.get()).get("email") as string | undefined;
  if (email) {
    try {
      await providers().email.send(
        email,
        "Your Hydro Sense mobile number was changed",
        [
          `Your mobile number was changed to one ending in ${pending.slice(-4)} on ${formatManila(Date.now())}.`,
          "Alerts and sign-in codes now go to the new number.",
          "",
          "If this wasn't you, contact your Hydro Sense provider.",
        ].join("\n"),
      );
    } catch (e) {
      await logError({ source: "confirmPhoneChange", code: "EMAIL_FAILED", message: String(e) });
    }
  }
  return { phone: maskPhone(pending) };
});

/**
 * After a password sign-in in the app. A user can set a password with
 * Firebase's emailed reset link, which the server never sees, so the
 * profile learns "Password set" here. Only a session that was opened with a
 * password counts, so a custom-token session from the SMS flow proves nothing.
 */
export const syncPasswordSet = onCall(async (request) => {
  const uid = await requireUser(request);
  const provider = (request.auth?.token.firebase as { sign_in_provider?: string } | undefined)
    ?.sign_in_provider;
  if (provider !== "password") return { passwordSet: false, changed: false };
  const ref = db.collection(C.users).doc(uid);
  if ((await ref.get()).get("passwordSet") === true) return { passwordSet: true, changed: false };
  await ref.update({ passwordSet: true });
  return { passwordSet: true, changed: true };
});

/** After the user opens Firebase's verify-before-update link. */
export const syncMyEmail = onCall(async (request) => {
  const uid = await requireUser(request);
  const authEmail = (await getAuth().getUser(uid)).email?.toLowerCase() ?? null;
  const ref = db.collection(C.users).doc(uid);
  if (authEmail && authEmail !== (await ref.get()).get("email")) {
    await ref.update({ email: authEmail });
  }
  return { email: authEmail };
});

/** Notifies the admins; the account stays active until an admin deletes it. */
export const requestAccountDeletion = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const uid = await requireUser(request);
  const ref = db.collection(C.users).doc(uid);
  const user = await ref.get();
  if (user.get("deletionRequestedAt")) return { alreadyRequested: true };
  const nowMs = Date.now();
  await ref.update({ deletionRequestedAt: ts(nowMs) });
  const name = (user.get("name") as string | undefined) ?? uid;
  await audit({
    adminUid: uid,
    actor: { name, email: (user.get("email") as string | undefined) ?? null },
    action: "deletion_requested",
    targetId: uid,
    targetName: name,
    nowMs,
  });
  return { alreadyRequested: false };
});
