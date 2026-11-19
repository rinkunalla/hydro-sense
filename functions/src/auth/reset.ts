// Set or reset a user's password with a 6-digit code sent by email (the main
// way, D59) or by SMS (CLAUDE.md D22, section 6). These callables need no
// sign-in, so every reply is the same whether or not the address belongs to an
// account.
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/https";
import { MIN_PASSWORD_LENGTH, RESET_TOKEN_TTL_S } from "../config";
import { C, db, ms, ts } from "../lib/db";
import { newOneTimeToken, uidOfToken } from "../lib/otp";
import { OTP_SECRETS } from "../lib/providers";
import { sha256Hex } from "../lib/tokens";
import { parseEmail, parsePhone } from "../lib/userInput";
import { checkCode, sendCode } from "./codes";

/** The account a code may go to: an active user who owns this number, else null. */
async function resetAccount(phone: string): Promise<string | null> {
  const uid = (await db.collection(C.phoneIndex).doc(phone).get()).get("uid") as string | undefined;
  if (!uid) return null;
  const user = await db.collection(C.users).doc(uid).get();
  return user.get("role") === "user" && user.get("status") === "active" ? uid : null;
}

/** An active user whose account email is this address, else null. */
async function resetAccountByEmail(email: string): Promise<string | null> {
  try {
    const uid = (await getAuth().getUserByEmail(email)).uid;
    const user = await db.collection(C.users).doc(uid).get();
    return user.get("role") === "user" && user.get("status") === "active" ? uid : null;
  } catch {
    return null; // no such account: same reply as a real one
  }
}

/** {email} or {mobile}: where the code goes, and the account it may reset. */
async function resetTarget(d: Record<string, unknown>) {
  if (d.email !== undefined) {
    const email = parseEmail(d.email);
    return { address: email, channel: "email" as const, uid: await resetAccountByEmail(email) };
  }
  const phone = parsePhone(d.mobile);
  return { address: phone, channel: "sms" as const, uid: await resetAccount(phone) };
}

export function parsePassword(v: unknown): string {
  if (typeof v !== "string" || v.length < MIN_PASSWORD_LENGTH || v.length > 128) {
    throw new HttpsError("invalid-argument", `Use at least ${MIN_PASSWORD_LENGTH} characters.`, {
      code: "PASSWORD_WEAK",
    });
  }
  return v;
}

export const requestResetCode = onCall({ secrets: OTP_SECRETS }, async (request) => {
  const t = await resetTarget((request.data ?? {}) as Record<string, unknown>);
  const resendAfterSeconds = await sendCode({
    phone: t.address,
    channel: t.channel,
    uid: t.uid,
    purpose: "reset",
  });
  return { ok: true, resendAfterSeconds };
});

export const verifyResetCode = onCall(async (request) => {
  const d = (request.data ?? {}) as Record<string, unknown>;
  const { address, uid } = await resetTarget(d);
  const { token, hash } = newOneTimeToken(uid ?? "none");
  const nowMs = Date.now();
  await checkCode(address, uid, "reset", d.code, (tx, doc) => {
    tx.update(doc.ref, {
      resetTokenHash: hash,
      resetTokenExpiresAt: ts(nowMs + RESET_TOKEN_TTL_S * 1000),
    });
  });
  return { resetToken: token };
});

export const setPasswordWithResetToken = onCall(async (request) => {
  const d = (request.data ?? {}) as Record<string, unknown>;
  const password = parsePassword(d.newPassword);
  const invalid = () =>
    new HttpsError("permission-denied", "This reset has expired. Start again.", {
      code: "RESET_TOKEN_INVALID",
    });
  const uid = uidOfToken(d.resetToken);
  if (!uid) throw invalid();

  const ref = db.collection(C.passwordResets).doc(uid);
  const nowMs = Date.now();
  // Used up inside the transaction, so a token works exactly once.
  await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const stored = doc.get("resetTokenHash") as string | null | undefined;
    const expires = ms(doc.get("resetTokenExpiresAt"));
    const ok =
      doc.get("purpose") === "reset" &&
      typeof stored === "string" &&
      stored === sha256Hex(d.resetToken as string) &&
      expires !== null &&
      expires > nowMs;
    if (!ok) throw invalid();
    tx.delete(ref);
  });

  const user = await db.collection(C.users).doc(uid).get();
  if (user.get("status") !== "active") throw invalid();
  await getAuth().updateUser(uid, { password });
  await user.ref.update({ passwordSet: true });
  await getAuth().revokeRefreshTokens(uid);
  // The app signs in with this email and the new password ("You're signed in").
  return { email: user.get("email") as string };
});
