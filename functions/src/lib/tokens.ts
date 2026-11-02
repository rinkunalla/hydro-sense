import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

export const generateToken = () => randomBytes(32).toString("base64url");

export const sha256Hex = (s: string) => createHash("sha256").update(s, "utf8").digest("hex");

/** Constant-time string comparison; hashing first gives both sides the same length. */
export function safeEqual(a: string, b: string): boolean {
  return timingSafeEqual(Buffer.from(sha256Hex(a), "hex"), Buffer.from(sha256Hex(b), "hex"));
}
