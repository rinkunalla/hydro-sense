import { HttpsError, type CallableRequest } from "firebase-functions/https";

export function requireAdmin(request: CallableRequest): string {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.", { code: "NOT_ADMIN" });
  if (auth.token.role !== "admin") {
    throw new HttpsError("permission-denied", "Admins only.", { code: "NOT_ADMIN" });
  }
  return auth.uid;
}

export function requireClient(request: CallableRequest): string {
  const auth = request.auth;
  if (!auth) throw new HttpsError("unauthenticated", "Sign in first.", { code: "NOT_CLIENT" });
  if (auth.token.role !== "client") {
    throw new HttpsError("permission-denied", "Clients only.", { code: "NOT_CLIENT" });
  }
  return auth.uid;
}
