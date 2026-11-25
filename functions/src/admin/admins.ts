// Admin accounts. Admins are created only by tools/seed-admins.ts (no invites
// on the website since 2026-11-25) and set their password with a one-time setup
// link that works once and expires in ADMIN_SETUP_TOKEN_TTL_S. Only the link's
// hash is stored.
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/https";
import {
  ADMIN_RECOMMENDED_MIN,
  ADMIN_SETUP_MAX_PER_HOUR,
  ADMIN_SETUP_TOKEN_TTL_S,
  ADMIN_SITE_URL,
} from "../config";
import { requireAdmin, requireAdminClaim } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { setMember } from "../lib/members";
import { MAIL_SECRETS, providers } from "../lib/providers";
import { newOneTimeToken, sha256Hex, uidOfToken } from "../lib/tokens";
import {
  parseEmail,
  parseName,
  parseOptionalPhone,
  parsePassword,
  parseUid,
} from "../lib/userInput";
import { assertPhoneFree, movePhone } from "./staff";

const HOUR_MS = 3_600_000;
const SOURCE = "admins";

const adminRef = (uid: string) => db.collection(C.admins).doc(uid);
const tokenRef = (uid: string) => db.collection(C.adminSetupTokens).doc(uid);

const fail = (
  status: "failed-precondition" | "not-found" | "resource-exhausted",
  code: string,
  m: string,
) => new HttpsError(status, m, { code });

export type LinkResult = "sent" | "failed" | "limited";

/**
 * Issues a fresh setup link for an invited admin and emails it. Counts toward
 * ADMIN_SETUP_MAX_PER_HOUR (project-wide, transaction). A new link replaces the old one.
 */
export async function sendSetupLink(
  uid: string,
  email: string,
  nowMs = Date.now(),
): Promise<LinkResult> {
  const rateRef = db.collection(C.rateLimits).doc(`admin_setup__${Math.floor(nowMs / HOUR_MS)}`);
  const { token, hash } = newOneTimeToken(uid);
  const allowed = await db.runTransaction(async (tx) => {
    const rate = await tx.get(rateRef);
    const count = (rate.get("count") as number | undefined) ?? 0;
    if (count >= ADMIN_SETUP_MAX_PER_HOUR) return false;
    tx.set(rateRef, { count: count + 1, expireAt: ts(nowMs + 2 * HOUR_MS) });
    tx.set(tokenRef(uid), {
      tokenHash: hash,
      expiresAt: ts(nowMs + ADMIN_SETUP_TOKEN_TTL_S * 1000),
    });
    tx.update(adminRef(uid), { inviteSentAt: ts(nowMs) });
    return true;
  });
  if (!allowed) return "limited";

  const link = `${ADMIN_SITE_URL}/setup?token=${encodeURIComponent(token)}`;
  try {
    await providers().email.send(
      email,
      "Set up your Hydro Sense admin account",
      [
        "Use this link to set your password. It works once and expires in 1 hour.",
        "If you did not ask for this, ignore this email.",
        "",
        link,
      ].join("\n"),
    );
    return "sent";
  } catch (e) {
    await logError({ source: SOURCE, code: "EMAIL_FAILED", message: String(e), nowMs });
    return "failed";
  }
}

/** Unauthenticated: the same reply for every email (no enumeration). */
export const requestAdminSetup = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  let email: string;
  try {
    email = parseEmail((request.data as { email?: unknown } | null)?.email);
  } catch {
    return { ok: true };
  }
  const match = await db.collection(C.admins).where("email", "==", email).limit(1).get();
  const admin = match.docs[0];
  if (admin && admin.get("status") === "invited") await sendSetupLink(admin.id, email);
  return { ok: true };
});

/** Unauthenticated: sets the password with a valid setup link (once, within 1 hour). */
export const completeAdminSetup = onCall(async (request) => {
  const d = (request.data ?? {}) as Record<string, unknown>;
  const password = parsePassword(d.password);
  const invalid = () =>
    new HttpsError("permission-denied", "This link has expired or was already used.", {
      code: "RESET_TOKEN_INVALID",
    });
  const uid = uidOfToken(d.token);
  if (!uid) throw invalid();
  const nowMs = Date.now();
  await db.runTransaction(async (tx) => {
    const [tok, admin] = await Promise.all([tx.get(tokenRef(uid)), tx.get(adminRef(uid))]);
    const expires = ms(tok.get("expiresAt"));
    const ok =
      tok.get("tokenHash") === sha256Hex(d.token as string) &&
      expires !== null &&
      expires > nowMs &&
      admin.get("status") === "invited";
    if (!ok) throw invalid();
    tx.delete(tok.ref);
  });
  await getAuth().updateUser(uid, { password, emailVerified: true });
  return { email: (await adminRef(uid).get()).get("email") as string };
});

/**
 * Removes another active admin. The count check and the delete share one
 * transaction, so two admins removing each other at once cannot leave zero.
 */
export const removeAdmin = onCall(async (request) => {
  const by = await requireAdmin(request);
  const uid = parseUid((request.data as { uid?: unknown } | null)?.uid);
  if (uid === by) {
    throw fail("failed-precondition", "SELF_REMOVE", "Ask another admin to remove you.");
  }
  await db.runTransaction(async (tx) => {
    const active = await tx.get(db.collection(C.admins).where("status", "==", "active"));
    const ids = active.docs.map((d) => d.id);
    const target = active.docs.find((d) => d.id === uid);
    if (!target) throw fail("not-found", "USER_NOT_FOUND", "Admin not found.");
    if (!ids.includes(by) || ids.length <= 1) {
      throw fail(
        "failed-precondition",
        "LAST_ADMIN",
        "You can't remove the only admin.",
      );
    }
    tx.delete(target.ref);
    const held = (target.get("phone") as string | null | undefined) ?? null;
    if (held) tx.delete(db.collection(C.phoneIndex).doc(held));
  });
  await setMember(uid, false);
  await getAuth()
    .deleteUser(uid)
    .catch((e: { code?: string }) => {
      if (e.code !== "auth/user-not-found") throw e;
    });
  await tokenRef(uid).delete();
  return { uid };
});

export const listAdmins = onCall(async (request) => {
  const me = await requireAdmin(request);
  const snap = await db.collection(C.admins).get();
  const auth = snap.empty
    ? { users: [] }
    : await getAuth().getUsers(snap.docs.map((d) => ({ uid: d.id })));
  const lastSignIn = new Map(
    auth.users.map((u) => [
      u.uid,
      u.metadata.lastSignInTime ? Date.parse(u.metadata.lastSignInTime) : null,
    ]),
  );
  const nowMs = Date.now();
  const admins = snap.docs.map((d) => {
    const sentMs = ms(d.get("inviteSentAt"));
    const invited = d.get("status") === "invited";
    return {
      uid: d.id,
      name: d.get("name") ?? null,
      email: d.get("email") ?? null,
      phone: d.get("phone") ?? null,
      status: d.get("status"),
      you: d.id === me,
      inviteSentAtMs: sentMs,
      inviteExpired:
        invited && (sentMs === null || sentMs + ADMIN_SETUP_TOKEN_TTL_S * 1000 <= nowMs),
      lastSignInMs: lastSignIn.get(d.id) ?? null,
      activatedAtMs: ms(d.get("activatedAt")),
    };
  });
  const activeCount = admins.filter((a) => a.status === "active").length;
  return { admins, belowRecommended: activeCount < ADMIN_RECOMMENDED_MIN };
});

export const updateMyAdminName = onCall(async (request) => {
  const uid = await requireAdmin(request);
  const name = parseName((request.data as { name?: unknown } | null)?.name);
  await adminRef(uid).update({ name });
  await getAuth().updateUser(uid, { displayName: name });
  return { name };
});

/**
 * {mobile}: the admin's own mobile number for SMS alerts (D65); null or ""
 * removes it. Unique across staff and admins (phone_index).
 */
export const updateMyAdminMobile = onCall(async (request) => {
  const uid = await requireAdmin(request);
  const phone = parseOptionalPhone((request.data as { mobile?: unknown } | null)?.mobile) ?? null;
  await assertPhoneFree(uid, phone);
  await db.runTransaction(async (tx) => {
    const ref = adminRef(uid);
    const old = ((await tx.get(ref)).get("phone") as string | null | undefined) ?? null;
    await movePhone(tx, uid, old, phone);
    tx.update(ref, { phone });
  });
  return { phone };
});

/**
 * Called by the website after every admin sign-in: marks an invited admin active
 * on the first sign-in, and copies a verified new email into the record.
 */
export const syncMyAdmin = onCall(async (request) => {
  const uid = await requireAdminClaim(request);
  const ref = adminRef(uid);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("permission-denied", "Admins only.", { code: "NOT_ADMIN" });
  }
  const user = await getAuth().getUser(uid);
  const update: Record<string, unknown> = {};
  if (snap.get("status") === "invited") {
    update.status = "active";
    update.activatedAt = ts(Date.now());
  }
  const authEmail = user.email?.toLowerCase();
  if (authEmail && user.emailVerified && authEmail !== snap.get("email")) update.email = authEmail;
  if (Object.keys(update).length > 0) await ref.update(update);
  // Active admins read the live channel (D62); this also repairs a missing entry.
  await setMember(uid, true);
  return { status: (update.status as string | undefined) ?? snap.get("status") };
});

/** Ends every session of the caller, including this one. */
export const signOutEverywhere = onCall(async (request) => {
  const uid = await requireAdmin(request);
  await getAuth().revokeRefreshTokens(uid);
  return { ok: true };
});
