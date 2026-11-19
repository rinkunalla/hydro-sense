// Pure alert gate. One state per device per family:
// flow (flow_low and flow_none share it), battery_low, offline.
import {
  ABNORMAL_CONFIRM_S,
  ALERT_LOCK_S,
  ALERT_MAX_REMINDERS,
  BATTERY_REARM_PERCENT,
  LOW_BATTERY_PERCENT,
  OFFLINE_ALERT_AFTER_S,
  RECOVERY_CONFIRM_S,
} from "../config";
import type { AlertType } from "./messages";
import type { FlowStatus } from "./payload";

const S = 1000;

export type Family = "flow" | "battery_low" | "offline";
export const FAMILIES: readonly Family[] = ["flow", "battery_low", "offline"];

export interface AlertState {
  active: boolean;
  lastSentAtMs: number | null;
  lockedUntilMs: number | null;
  lastType: AlertType | null;
  reminders: number;
  recoveredSinceMs: number | null;
}

export const EMPTY_STATE: AlertState = {
  active: false,
  lastSentAtMs: null,
  lockedUntilMs: null,
  lastType: null,
  reminders: 0,
  recoveredSinceMs: null,
};

/** What the device looks like right now for one family. */
export type Condition =
  | { kind: "fault"; type: AlertType }
  | { kind: "recovered" }
  | { kind: "neutral" } // not faulty, not (yet) counting as recovered
  | { kind: "skip" }; // do not evaluate (offline for flow/battery, paused)

export interface DeviceView {
  online: boolean;
  lastSeenMs: number | null;
  flowStatus: FlowStatus | null;
  abnormalSinceMs: number | null;
  batteryPercent: number | null;
  batteryFault: boolean;
}

export function flowCondition(d: DeviceView, nowMs: number): Condition {
  if (!d.online) return { kind: "skip" };
  if (d.flowStatus === "Normal Flow") return { kind: "recovered" };
  if (
    (d.flowStatus === "Low Flow" || d.flowStatus === "No Flow") &&
    d.abnormalSinceMs !== null &&
    nowMs - d.abnormalSinceMs >= ABNORMAL_CONFIRM_S * S
  ) {
    return { kind: "fault", type: d.flowStatus === "No Flow" ? "flow_none" : "flow_low" };
  }
  return { kind: "neutral" };
}

export function batteryCondition(d: DeviceView): Condition {
  if (!d.online) return { kind: "skip" };
  if (d.batteryFault || d.batteryPercent === null) return { kind: "neutral" };
  if (d.batteryPercent < LOW_BATTERY_PERCENT) return { kind: "fault", type: "battery_low" };
  if (d.batteryPercent > BATTERY_REARM_PERCENT) return { kind: "recovered" };
  return { kind: "neutral" };
}

export function offlineCondition(d: DeviceView, nowMs: number): Condition {
  if (d.online) return { kind: "recovered" };
  if (d.lastSeenMs !== null && nowMs - d.lastSeenMs >= OFFLINE_ALERT_AFTER_S * S) {
    return { kind: "fault", type: "offline" };
  }
  return { kind: "neutral" };
}

export function conditionFor(family: Family, d: DeviceView, nowMs: number): Condition {
  switch (family) {
    case "flow":
      return flowCondition(d, nowMs);
    case "battery_low":
      return batteryCondition(d);
    case "offline":
      return offlineCondition(d, nowMs);
  }
}

export interface Decision {
  send: { type: AlertType; reminder: boolean } | null;
  next: AlertState;
}

const locked = (s: AlertState, nowMs: number) =>
  s.lockedUntilMs !== null && nowMs < s.lockedUntilMs;

export function decide(state: AlertState, cond: Condition, nowMs: number): Decision {
  const keep = { send: null, next: state };
  switch (cond.kind) {
    case "skip":
      return keep;

    case "neutral":
      return state.recoveredSinceMs === null
        ? keep
        : { send: null, next: { ...state, recoveredSinceMs: null } };

    case "recovered": {
      if (!state.active) return keep;
      const since = state.recoveredSinceMs ?? nowMs;
      if (nowMs - since >= RECOVERY_CONFIRM_S * S) return { send: null, next: EMPTY_STATE };
      return since === state.recoveredSinceMs
        ? keep
        : { send: null, next: { ...state, recoveredSinceMs: since } };
    }

    case "fault": {
      const lock = nowMs + ALERT_LOCK_S * S;
      const base = { ...state, recoveredSinceMs: null };
      if (!state.active) {
        return {
          send: { type: cond.type, reminder: false },
          next: { ...EMPTY_STATE, active: true, lastType: cond.type, lastSentAtMs: nowMs, lockedUntilMs: lock },
        };
      }
      if (state.lastType === "flow_low" && cond.type === "flow_none") {
        return {
          send: { type: "flow_none", reminder: false },
          next: { ...base, lastType: "flow_none", lastSentAtMs: nowMs, lockedUntilMs: lock },
        };
      }
      if (!locked(state, nowMs) && state.reminders < ALERT_MAX_REMINDERS) {
        return {
          send: { type: cond.type, reminder: true },
          next: { ...base, reminders: state.reminders + 1, lastSentAtMs: nowMs, lockedUntilMs: lock },
        };
      }
      return state.recoveredSinceMs === null ? keep : { send: null, next: base };
    }
  }
}

export const sameState = (a: AlertState, b: AlertState) =>
  a.active === b.active &&
  a.lastSentAtMs === b.lastSentAtMs &&
  a.lockedUntilMs === b.lockedUntilMs &&
  a.lastType === b.lastType &&
  a.reminders === b.reminders &&
  a.recoveredSinceMs === b.recoveredSinceMs;
