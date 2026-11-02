import {
  DEVICES_WRITE_MAX_AGE_S,
  DEVICES_WRITE_MIN_INTERVAL_S,
  OFFLINE_AFTER_S,
  RATE_WRITE_DELTA_PCT,
  RATE_WRITE_MIN_ABS,
} from "../config";
import type { FlowStatus } from "./payload";

const S = 1000;

export const isAbnormal = (s: FlowStatus | null) => s === "Low Flow" || s === "No Flow";

/**
 * Set when entering Low/No Flow from Normal (or from no reading), kept while
 * moving between Low and No Flow, cleared on Normal (CLAUDE.md section 6).
 */
export function nextAbnormalSince(
  prevStatus: FlowStatus | null,
  prevAbnormalSinceMs: number | null,
  nextStatus: FlowStatus,
  nowMs: number,
): number | null {
  if (!isAbnormal(nextStatus)) return null;
  if (isAbnormal(prevStatus) && prevAbnormalSinceMs !== null) return prevAbnormalSinceMs;
  return nowMs;
}

/** At least RATE_WRITE_DELTA_PCT percent and RATE_WRITE_MIN_ABS L/min. */
export function rateChangedEnough(prevRate: number | null, nextRate: number): boolean {
  if (prevRate === null) return true;
  const delta = Math.abs(nextRate - prevRate);
  return delta >= RATE_WRITE_MIN_ABS && delta >= (RATE_WRITE_DELTA_PCT / 100) * prevRate;
}

export interface DevicesWriteInput {
  statusChanged: boolean;
  locationChanged: boolean;
  prevRate: number | null;
  nextRate: number;
  updatedAtMs: number | null;
  nowMs: number;
}

/** deviceIngest writes `devices` only when this is true (CLAUDE.md section 6). */
export function shouldWriteDevices(i: DevicesWriteInput): boolean {
  if (i.statusChanged || i.locationChanged || i.updatedAtMs === null) return true;
  const ageMs = i.nowMs - i.updatedAtMs;
  if (ageMs >= DEVICES_WRITE_MAX_AGE_S * S) return true;
  return rateChangedEnough(i.prevRate, i.nextRate) && ageMs >= DEVICES_WRITE_MIN_INTERVAL_S * S;
}

/** One sample per interval: true when never sampled or the last sample is old enough. */
export function sampleDue(lastAtMs: number | null, nowMs: number, intervalS: number): boolean {
  return lastAtMs === null || nowMs - lastAtMs >= intervalS * S;
}

/** A device is stale (should flip offline) after OFFLINE_AFTER_S of silence. */
export function isStale(lastSeenMs: number | null, nowMs: number): boolean {
  return lastSeenMs !== null && nowMs - lastSeenMs >= OFFLINE_AFTER_S * S;
}
