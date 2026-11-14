// Set or reset a user's password by SMS code (CLAUDE.md D22, section 6). These
// callables need no sign-in, so every reply is the same whether or not the
// mobile number belongs to an account.
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/https";
import { MIN_PASSWORD_LENGTH, RESET_TOKEN_TTL_S } from "../config";
import { C, db, ms, ts } from "../lib/db";
import { newOneTimeToken, uidOfToken } from "../lib/otp";
import { OTP_SECRETS } from "../lib/providers";
import { sha256Hex } from "../lib/tokens";
import { parsePhone } from "../lib/userInput";
import { checkCode, sendCode } from "./codes";

/** The account a code may go to: an active user who owns this number, else null. */
async function resetAccount(phone: string): Promise<string | null> {
  const uid = (await db.collection(C.phoneIndex).doc(phone).get()).get("uid") as string | undefined;
  if (!uid) return null;
  const user = await db.collection(C.users).doc(uid).get();
  return user.get("role") === "user" && user.get("status") === "active" ? uid : null;
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
  const phone = parsePhone((request.data as { mobile?: unknown } | null)?.mobile);
  const uid = await resetAccount(phone);
  const resendAfterSeconds = await sendCode({ phone, uid, purpose: "reset" });
  return { ok: true, resendAfterSeconds };
});

export const verifyResetCode = onCall(async (request) => {
  const d = (request.data ?? {}) as Record<string, unknown>;
  const phone = parsePhone(d.mobile);
  const uid = await resetAccount(phone);
  const { token, hash } = newOneTimeToken(uid ?? "none");
  const nowMs = Date.now();
  await checkCode(phone, uid, "reset", d.code, (tx, doc) => {
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
