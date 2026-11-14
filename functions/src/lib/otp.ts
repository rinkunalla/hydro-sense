// Pure helpers for sign-in codes and one-time tokens (CLAUDE.md D22, D23, D31).
// Only hashes are ever stored; the code or token itself leaves the server once.
import { randomInt } from "node:crypto";
import {
  OTP_PROJECT_DAILY_CAP,
  RESET_CODE_LENGTH,
  RESET_MAX_ATTEMPTS,
  RESET_MAX_PER_PHONE_DAY,
  RESET_RESEND_S,
} from "../config";
import { generateToken, sha256Hex } from "./tokens";

/** A uniformly random code with leading zeros kept ("004271"). */
export const generateCode = () =>
  String(randomInt(10 ** RESET_CODE_LENGTH)).padStart(RESET_CODE_LENGTH, "0");

/** The code is bound to its account, so equal codes for two users hash differently. */
export const codeHash = (uid: string, code: string) => sha256Hex(`${uid}:${code}`);

/**
 * "<uid>.<random>": the uid finds the stored hash without a query; the random
 * part is the secret. Only sha256(token) is stored.
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

/** "0917 ••• 4567" from 639171234567 (docs/UI_UX_SPEC.md 5.2). */
export function maskPhone(phone: string): string {
  const local = phone.startsWith("63") ? `0${phone.slice(2)}` : phone;
  return `${local.slice(0, 4)} ••• ${local.slice(-4)}`;
}

export const codeSms = (code: string) =>
  `Hydro Sense: your code is ${code}. It expires in 5 minutes. Never share this code.`;

export interface SendCounters {
  /** Last send to this phone, ms. */
  lastSentMs: number | null;
  /** Codes sent to this phone today (Asia/Manila). */
  phoneToday: number;
  /** Code SMS sent by the whole project today. */
  projectToday: number;
}

export type SendDecision =
  | { kind: "send" }
  | { kind: "cooldown"; retryAfterSeconds: number }
  | { kind: "phone_limit" }
  | { kind: "project_limit" };

/**
 * Whether a code may be sent now. The resend gap comes first so a quick double
 * tap never burns one of the day's codes.
 */
export function sendDecision(c: SendCounters, nowMs: number): SendDecision {
  if (c.lastSentMs !== null) {
    const waitMs = c.lastSentMs + RESET_RESEND_S * 1000 - nowMs;
    if (waitMs > 0) return { kind: "cooldown", retryAfterSeconds: Math.ceil(waitMs / 1000) };
  }
  if (c.phoneToday >= RESET_MAX_PER_PHONE_DAY) return { kind: "phone_limit" };
  if (c.projectToday >= OTP_PROJECT_DAILY_CAP) return { kind: "project_limit" };
  return { kind: "send" };
}

export interface CodeState {
  /** Wrong tries so far for this code. */
  attempts: number;
  /** When the code expires; null when no code is waiting (never sent, or used). */
  expiresAtMs: number | null;
  /** The typed code matches the stored hash. */
  matches: boolean;
}

export type CodeVerdict =
  | { kind: "ok" }
  | { kind: "invalid"; triesLeft: number }
  | { kind: "expired" }
  | { kind: "locked" };

/**
 * The answer to one typed code (docs/UI_UX_SPEC.md 5.2): right, wrong with the
 * tries left, expired, or locked after RESET_MAX_ATTEMPTS wrong tries.
 * The caller adds 1 to attempts only on an "invalid" verdict.
 */
export function codeVerdict(s: CodeState, nowMs: number): CodeVerdict {
  // Locked wins even over the right code: five wrong tries end this code.
  if (s.attempts >= RESET_MAX_ATTEMPTS) return { kind: "locked" };
  const triesLeft = RESET_MAX_ATTEMPTS - 1 - s.attempts;
  // No code waiting answers like a wrong code; "expired" would reveal that one existed.
  if (s.expiresAtMs === null) return { kind: "invalid", triesLeft };
  if (s.expiresAtMs <= nowMs) return { kind: "expired" };
  return s.matches ? { kind: "ok" } : { kind: "invalid", triesLeft };
}
