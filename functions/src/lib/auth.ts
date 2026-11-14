import { HttpsError, type CallableRequest } from "firebase-functions/https";
import { C, db } from "./db";

// An ID token stays valid for up to an hour after its account is removed or
// suspended (revoking only stops refreshes), so the claim alone is not enough:
// each check also reads the live record, which ends access at once.

const denied = (code: "NOT_ADMIN" | "NOT_USER", message: string) =>
  new HttpsError("permission-denied", message, { code });

/** Signed-in admin with an active admins/{uid} record (D23, D40). Returns the uid. */
export async function requireAdmin(request: CallableRequest): Promise<string> {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.", { code: "NOT_ADMIN" });
  if (auth.token.role !== "admin") throw denied("NOT_ADMIN", "Admins only.");
  const record = await db.collection(C.admins).doc(auth.uid).get();
  if (record.get("status") !== "active") throw denied("NOT_ADMIN", "Admins only.");
  return auth.uid;
}

/**
 * Like requireAdmin, but also lets an invited admin through: used only by
 * syncMyAdmin, which marks the record active on the first sign-in.
 */
export async function requireAdminClaim(request: CallableRequest): Promise<string> {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.", { code: "NOT_ADMIN" });
  if (auth.token.role !== "admin") throw denied("NOT_ADMIN", "Admins only.");
  return auth.uid;
}

/** Signed-in user whose account is active (not suspended, D42). Returns the uid. */
export async function requireUser(request: CallableRequest): Promise<string> {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.", { code: "NOT_USER" });
  if (auth.token.role !== "user") throw denied("NOT_USER", "Users only.");
  const user = await db.collection(C.users).doc(auth.uid).get();
  if (user.get("status") !== "active") throw denied("NOT_USER", "Users only.");
  return auth.uid;
}

/** Seconds since the caller last typed their password (ID token auth_time). */
export function secondsSinceSignIn(request: CallableRequest, nowMs = Date.now()): number {
  const authTime = Number(request.auth?.token.auth_time ?? 0);
  return Math.floor(nowMs / 1000) - authTime;
}
