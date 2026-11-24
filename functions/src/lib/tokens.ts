import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

export const generateToken = () => randomBytes(32).toString("base64url");

export const sha256Hex = (s: string) => createHash("sha256").update(s, "utf8").digest("hex");

/** Constant-time string comparison; hashing first gives both sides the same length. */
export function safeEqual(a: string, b: string): boolean {
  return timingSafeEqual(Buffer.from(sha256Hex(a), "hex"), Buffer.from(sha256Hex(b), "hex"));
}

/**
 * "<uid>.<random>": the uid finds the stored hash without a query; the random
 * part is the secret. Only sha256(token) is stored (admin setup links).
 */
export function newOneTimeToken(uid: string): { token: string; hash: string } {
  const token = `${uid}.${generateToken()}`;
  return { token, hash: sha256Hex(token) };
}

export function uidOfToken(token: unknown): string | null {
  if (typeof token !== "string" || token.length > 300) return null;
  const dot = token.indexOf(".");
  return dot > 0 ? token.slice(0, dot) : null;
}
