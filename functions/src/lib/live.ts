// What one upload changes, as pure logic: the next /live node, the
// /state patch, which problem records to open or close, and whether Firestore
// needs a flow sample or a GPS update. deviceIngest applies the result.
import { ABNORMAL_CONFIRM_S, BATTERY_REARM_PERCENT, FLOW_LOG_SAMPLE_S, LOW_BATTERY_PERCENT } from "../config";
import { appendVoltage, batteryPercent, chargingTrend, smoothedVoltage, type ChargingStatus } from "./battery";
import { nextAbnormalSince, sampleDue } from "./decisions";
import type { FlowStatus, IngestPayload } from "./payload";

export const PROBLEM_TYPES = ["no_flow", "low_flow", "offline", "battery_low"] as const;
export type ProblemType = (typeof PROBLEM_TYPES)[number];

/** Owner-readable live node: /live/{id}. Times are epoch milliseconds. */
export interface Live {
  ownerUid: string | null;
  removed: boolean;
  online: boolean;
  lastSeen: number | null;
  flowStatus: FlowStatus | null;
  flowRate: number | null;
  abnormalSince: number | null;
  statusChangedAt: number | null;
  batteryPercent: number | null;
  chargingStatus: ChargingStatus | null;
  batteryFault: boolean;
  lowVoltageSleep: boolean;
  heartbeatS: number | null;
}

/** Server-only node: /state/{id}. Nobody but the functions reads it. */
export interface State {
  ownerUid: string | null;
  removed: boolean;
  tokenHash: string | null;
  lowFlowCutoff: number;
  normalFlowCutoff: number;
  recentVoltages: number[];
  lastSampleAt: number | null;
  gpsLat: number | null;
  gpsLng: number | null;
  firmware: string | null;
  /** The Manila day of today's live series; a new day drops older ones. */
  seriesDay: string | null;
  /** The live series minute last written ("yyyy-mm-dd/minute") and its peak. */
  seriesMinute: string | null;
  seriesPeak: number | null;
  /** Problem record IDs still open, by type. */
  open: Partial<Record<ProblemType, string>>;
}

export type ProblemOp =
  | { op: "open"; type: ProblemType; startedAt: number }
  | { op: "close"; type: ProblemType; id: string; endedAt: number; dropIfShort: boolean };

export interface UploadResult {
  live: Live;
  /** Fields of /state to overwrite (open problem IDs are set by the caller). */
  state: Pick<State, "recentVoltages" | "lastSampleAt" | "gpsLat" | "gpsLng">;
  problems: ProblemOp[];
  sample: boolean;
  gpsMoved: boolean;
}

const FLOW_PROBLEM: Partial<Record<FlowStatus, ProblemType>> = {
  "Low Flow": "low_flow",
  "No Flow": "no_flow",
};

/**
 * The flow kept for one minute of the live series: its highest reading. A
 * device can send several readings a minute; keeping only the last let a short
 * rise (17 L/min, then the tap closed) vanish under the drop that followed.
 */
export function minutePeak(
  prevMinute: string | null,
  prevPeak: number | null,
  minute: string,
  rate: number,
): number {
  return prevMinute === minute && prevPeak !== null ? Math.max(prevPeak, rate) : rate;
}

export const emptyLive =(ownerUid: string | null = null): Live => ({
  ownerUid,
  removed: false,
  online: false,
  lastSeen: null,
  flowStatus: null,
  flowRate: null,
  abnormalSince: null,
  statusChangedAt: null,
  batteryPercent: null,
  chargingStatus: null,
  batteryFault: false,
  lowVoltageSleep: false,
  heartbeatS: null,
});

/** A flow problem shorter than this is a blip: dropped when it closes. */
export const PROBLEM_MIN_MS = ABNORMAL_CONFIRM_S * 1000;

export function applyUpload(
  prev: Live,
  state: State,
  p: IngestPayload,
  nowMs: number,
): UploadResult {
  const problems: ProblemOp[] = [];
  const statusChanged = prev.flowStatus !== p.flowStatus;

  // Back online: the offline problem ends now.
  if (state.open.offline) {
    problems.push({ op: "close", type: "offline", id: state.open.offline, endedAt: nowMs, dropIfShort: false });
  }

  // Flow: close the old flow problem and open the new one on a status change.
  if (statusChanged) {
    const was = prev.flowStatus ? FLOW_PROBLEM[prev.flowStatus] : undefined;
    const now = FLOW_PROBLEM[p.flowStatus];
    const openId = was ? state.open[was] : undefined;
    if (was && openId) {
      problems.push({ op: "close", type: was, id: openId, endedAt: nowMs, dropIfShort: true });
    }
    if (now) problems.push({ op: "open", type: now, startedAt: nowMs });
  }

  // Battery: open below LOW_BATTERY_PERCENT, close above BATTERY_REARM_PERCENT (as the alert).
  let recent = state.recentVoltages;
  let pct: number | null = null;
  let charging: ChargingStatus | null = prev.chargingStatus;
  if (p.batteryVoltage !== null) {
    recent = appendVoltage(recent, p.batteryVoltage);
    pct = batteryPercent(smoothedVoltage(recent));
    charging = chargingTrend(recent);
    if (pct < LOW_BATTERY_PERCENT && !state.open.battery_low) {
      problems.push({ op: "open", type: "battery_low", startedAt: nowMs });
    } else if (pct > BATTERY_REARM_PERCENT && state.open.battery_low) {
      problems.push({
        op: "close",
        type: "battery_low",
        id: state.open.battery_low,
        endedAt: nowMs,
        dropIfShort: false,
      });
    }
  }

  const gpsMoved = p.gpsValid && (state.gpsLat !== p.lat || state.gpsLng !== p.lng);
  const sample = sampleDue(state.lastSampleAt, nowMs, FLOW_LOG_SAMPLE_S);

  return {
    live: {
      ownerUid: state.ownerUid,
      removed: state.removed,
      online: true,
      lastSeen: nowMs,
      flowStatus: p.flowStatus,
      flowRate: p.flowRate,
      abnormalSince: nextAbnormalSince(prev.flowStatus, prev.abnormalSince, p.flowStatus, nowMs),
      statusChangedAt: statusChanged ? nowMs : prev.statusChangedAt,
      batteryPercent: pct,
      chargingStatus: p.batteryVoltage === null ? null : charging,
      batteryFault: p.batteryFault,
      lowVoltageSleep: p.lowVoltageSleep,
      heartbeatS: p.heartbeatS,
    },
    state: {
      recentVoltages: recent,
      lastSampleAt: sample ? nowMs : state.lastSampleAt,
      gpsLat: gpsMoved ? p.lat : state.gpsLat,
      gpsLng: gpsMoved ? p.lng : state.gpsLng,
    },
    problems,
    sample,
    gpsMoved,
  };
}
