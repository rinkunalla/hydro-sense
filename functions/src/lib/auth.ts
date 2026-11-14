import { HttpsError, type CallableRequest } from "firebase-functions/https";

export function requireAdmin(request: CallableRequest): string {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.", { code: "NOT_ADMIN" });
  if (auth.token.role !== "admin") {
    throw new HttpsError("permission-denied", "Admins only.", { code: "NOT_ADMIN" });
  }
  return auth.uid;
}

export function requireUser(request: CallableRequest): string {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.", { code: "NOT_USER" });
  if (auth.token.role !== "user") {
    throw new HttpsError("permission-denied", "Users only.", { code: "NOT_USER" });
  }
  return auth.uid;
}
