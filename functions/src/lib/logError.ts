import { ERROR_LOG_DEDUPE_S, ERROR_LOG_MESSAGE_MAX, ERROR_LOG_TTL_DAYS } from "../config";
import { C, db, ts } from "./db";

const ALREADY_EXISTS = 6;
const DAY_MS = 86_400_000;

/** Removes email addresses and phone-number-like digit runs (provider errors can echo them). */
export const scrub = (s: string) =>
  s.replace(/[^\s@<>"']+@[^\s@<>"']+/g, "[email]").replace(/\+?\d[\d\s-]{8,}\d/g, "[number]");

export interface ErrorLogInput {
  source: string;
  code: string;
  message: string;
  deviceId?: string;
  nowMs?: number;
}

/**
 * The only writer of `error_logs`. The doc ID is
 * device + code + dedupe window, and `create()` fails if it exists, so a repeat inside
 * the same window costs one rejected write and no extra read. Never throws.
 * Never pass flow values, GPS, nicknames, phone numbers or emails in `message`.
 */
export async function logError(input: ErrorLogInput): Promise<void> {
  const nowMs = input.nowMs ?? Date.now();
  const window = Math.floor(nowMs / (ERROR_LOG_DEDUPE_S * 1000));
  const id = `${input.deviceId ?? "_"}__${input.code}__${window}`;
  try {
    await db
      .collection(C.errorLogs)
      .doc(id)
      .create({
        ...(input.deviceId ? { deviceId: input.deviceId } : {}),
        source: input.source,
        code: input.code,
        message: scrub(input.message).slice(0, ERROR_LOG_MESSAGE_MAX),
        ts: ts(nowMs),
        expireAt: ts(nowMs + ERROR_LOG_TTL_DAYS * DAY_MS),
      });
  } catch (e) {
    if ((e as { code?: number }).code === ALREADY_EXISTS) return;
    console.error(JSON.stringify({ severity: "ERROR", event: "logError_failed", code: input.code }));
  }
}
