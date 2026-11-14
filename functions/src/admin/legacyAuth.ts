import { onCall } from "firebase-functions/https";
import { requireUser } from "../lib/auth";
import { C, db } from "../lib/db";

/**
 * v1 sign-in step kept until stage 3 replaces it with the SMS-code flow (D22);
 * the stage 2 migration sets passwordSet for the existing account.
 */
export const confirmPasswordChanged = onCall(async (request) => {
  const uid = requireUser(request);
  await db.collection(C.users).doc(uid).set({ mustChangePassword: false }, { merge: true });
  return { ok: true };
});
