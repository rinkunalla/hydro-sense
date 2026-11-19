// Six-digit codes for password reset (by email or SMS) and mobile change (SMS).
// Limits are counted per address (phone number or
// email), also for addresses with no account, so the replies and their timing
// never tell a caller whether an address has an account.
import { HttpsError } from "firebase-functions/https";
import { EMAIL_CODE_PROJECT_DAILY_CAP, RESET_CODE_TTL_S, RESET_RESEND_S } from "../config";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import {
  codeEmail,
  codeHash,
  codeSms,
  codeVerdict,
  generateCode,
  sendDecision,
  type CodeVerdict,
} from "../lib/otp";
import { providers } from "../lib/providers";
import { manilaDateKey } from "../lib/time";

const SOURCE = "codes";
const DAY_MS = 86_400_000;

export type CodePurpose = "reset" | "phone_change";

/** Per phone per day: send count, last send, and wrong tries for unknown numbers. */
const phoneDayRef = (phone: string, nowMs: number) =>
  db.collection(C.rateLimits).doc(`otp__${phone}__${manilaDateKey(nowMs)}`);
const projectDayRef = (nowMs: number) => db.collection(C.alertDaily).doc(manilaDateKey(nowMs));
const resetRef = (uid: string) => db.collection(C.passwordResets).doc(uid);

/**
 * A code goes to `phone` (a mobile number, or with channel "email" an email
 * address) for account `uid`; uid null means "count, send nothing".
 */
export interface CodeTarget {
  phone: string;
  channel?: "sms" | "email";
  uid: string | null;
  purpose: CodePurpose;
  newPhone?: string;
}

/**
 * Applies the limits and, for a real account, stores a fresh code hash and sends
 * the SMS. Throws COOLDOWN or DAILY_LIMIT; otherwise returns the resend gap.
 */
export async function sendCode(t: CodeTarget, nowMs = Date.now()): Promise<number> {
  const code = generateCode();
  const byEmail = t.channel === "email";
  const projectField = byEmail ? "emailCodeCount" : "otpCount";
  const decision = await db.runTransaction(async (tx) => {
    const [phoneDay, projectDay] = await Promise.all([
      tx.get(phoneDayRef(t.phone, nowMs)),
      tx.get(projectDayRef(nowMs)),
    ]);
    const d = sendDecision(
      {
        lastSentMs: ms(phoneDay.get("lastSentAt")),
        phoneToday: (phoneDay.get("count") as number | undefined) ?? 0,
        projectToday: (projectDay.get(projectField) as number | undefined) ?? 0,
        projectCap: byEmail ? EMAIL_CODE_PROJECT_DAILY_CAP : undefined,
      },
      nowMs,
    );
    if (d.kind !== "send") return d;

    tx.set(
      phoneDayRef(t.phone, nowMs),
      {
        count: ((phoneDay.get("count") as number | undefined) ?? 0) + 1,
        lastSentAt: ts(nowMs),
        expireAt: ts(nowMs + 2 * DAY_MS),
        // A new code resets the wrong-try count, for unknown numbers too.
        ...(t.uid === null ? { decoyAttempts: 0 } : {}),
      },
      { merge: true },
    );
    if (t.uid !== null) {
      tx.set(
        projectDayRef(nowMs),
        {
          [projectField]: ((projectDay.get(projectField) as number | undefined) ?? 0) + 1,
        },
        { merge: true },
      );
      tx.set(resetRef(t.uid), {
        purpose: t.purpose,
        newPhone: t.newPhone ?? null,
        codeHash: codeHash(t.uid, code),
        expiresAt: ts(nowMs + RESET_CODE_TTL_S * 1000),
        attempts: 0,
        lastSentAt: ts(nowMs),
        resetTokenHash: null,
        resetTokenExpiresAt: null,
      });
    }
    return d;
  });

  if (decision.kind === "cooldown") {
    throw new HttpsError("resource-exhausted", "Wait before asking for another code.", {
      code: "COOLDOWN",
      retryAfterSeconds: decision.retryAfterSeconds,
    });
  }
  if (decision.kind !== "send") {
    if (decision.kind === "project_limit") {
      await logError({ source: SOURCE, code: "OTP_PROJECT_CAP_REACHED", message: "otp", nowMs });
    }
    throw new HttpsError("resource-exhausted", "Too many codes today. Try again tomorrow.", {
      code: "DAILY_LIMIT",
    });
  }

  if (t.uid !== null) {
    try {
      if (byEmail) {
        const mail = codeEmail(code);
        await providers().email.send(t.phone, mail.subject, mail.text);
      } else {
        const sent = await providers().otp.send(t.phone, codeSms("{otp}"), code);
        if (sent !== code) await resetRef(t.uid).update({ codeHash: codeHash(t.uid, sent) });
      }
    } catch (e) {
      // Same reply as success (no enumeration); the user can send again after the gap.
      const failed = byEmail ? "EMAIL_CODE_FAILED" : "OTP_FAILED";
      await logError({ source: SOURCE, code: failed, message: String(e), nowMs });
    }
  }
  return RESET_RESEND_S;
}

const codeError = (v: Exclude<CodeVerdict, { kind: "ok" }>) => {
  switch (v.kind) {
    case "invalid":
      return new HttpsError("invalid-argument", "That code is not right.", {
        code: "RESET_CODE_INVALID",
        triesLeft: v.triesLeft,
      });
    case "expired":
      return new HttpsError("deadline-exceeded", "This code has expired.", {
        code: "RESET_CODE_EXPIRED",
      });
    case "locked":
      return new HttpsError("resource-exhausted", "Too many wrong codes.", {
        code: "RESET_LOCKED",
      });
  }
};

/**
 * Checks a code. On success the code is used up and `onOk` runs inside the same
 * transaction (it may write). For a number with no account the wrong-try count
 * lives on the per-phone counter, so the replies match a real account's.
 */
export async function checkCode(
  phone: string,
  uid: string | null,
  purpose: CodePurpose,
  typed: unknown,
  onOk: (tx: FirebaseFirestore.Transaction, doc: FirebaseFirestore.DocumentSnapshot) => void,
  nowMs = Date.now(),
): Promise<void> {
  const code = typeof typed === "string" ? typed.trim() : "";
  const verdict = await db.runTransaction(async (tx) => {
    if (uid === null) {
      const ref = phoneDayRef(phone, nowMs);
      const decoy = await tx.get(ref);
      const attempts = (decoy.get("decoyAttempts") as number | undefined) ?? 0;
      // A stand-in code that "expires" like a real one, so waiting reveals nothing.
      const sentMs = ms(decoy.get("lastSentAt"));
      const expiresAtMs = sentMs === null ? null : sentMs + RESET_CODE_TTL_S * 1000;
      const v = codeVerdict({ attempts, expiresAtMs, matches: false }, nowMs);
      if (v.kind === "invalid") tx.set(ref, { decoyAttempts: attempts + 1 }, { merge: true });
      return v;
    }
    const doc = await tx.get(resetRef(uid));
    const stored = doc.get("codeHash") as string | null | undefined;
    const live = doc.exists && doc.get("purpose") === purpose && typeof stored === "string";
    const attempts = (doc.get("attempts") as number | undefined) ?? 0;
    const v = codeVerdict(
      {
        attempts,
        expiresAtMs: live ? ms(doc.get("expiresAt")) : null,
        matches: live && stored === codeHash(uid, code),
      },
      nowMs,
    );
    // Every wrong try counts, with or without a live code, like the stand-in above.
    if (v.kind === "invalid") tx.set(doc.ref, { attempts: attempts + 1 }, { merge: true });
    if (v.kind === "ok") {
      tx.update(doc.ref, { codeHash: null, attempts: 0 });
      onOk(tx, doc);
    }
    return v;
  });
  if (verdict.kind !== "ok") throw codeError(verdict);
}
