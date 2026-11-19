import { onSchedule } from "firebase-functions/scheduler";
import { runAlertPass, type AlertPassResult } from "../alerts/alertPass";
import { TIME_ZONE } from "../config";
import { liveRef, stateRef } from "../lib/db";
import { isStale } from "../lib/decisions";
import type { Live } from "../lib/live";
import { readAllLive, readState } from "../lib/liveStore";
import { logError } from "../lib/logError";
import { ALERT_SECRETS } from "../lib/providers";
import { applyProblemOps } from "../lib/problems";

const SOURCE = "monitorDevices";

/**
 * Flips one device offline only if the transaction still sees it stale, so an
 * upload landing at the same moment wins (D18). Returns its last-seen time.
 */
export async function flipOfflineIfStale(deviceId: string, nowMs: number): Promise<number | null> {
  let lastSeen: number | null = null;
  const r = await liveRef(deviceId).transaction((cur: Record<string, unknown> | null) => {
    if (cur === null) return cur; // the first read of a transaction may be empty: retried
    const hb = typeof cur.heartbeatS === "number" ? cur.heartbeatS : null;
    const seen = typeof cur.lastSeen === "number" ? cur.lastSeen : null;
    if (cur.online !== true || !isStale(seen, nowMs, hb)) return undefined; // abort
    lastSeen = seen;
    return { ...cur, online: false };
  });
  return r.committed && lastSeen !== null ? lastSeen : null;
}

/** Opens the Offline problem from the moment the device went silent (D49). */
async function openOfflineProblem(deviceId: string, sinceMs: number) {
  const state = await readState(deviceId);
  if (state.open.offline) return;
  const open = await applyProblemOps(deviceId, state.ownerUid, state.open, [
    { op: "open", type: "offline", startedAt: sinceMs },
  ]);
  await stateRef(deviceId).child("open").set(open);
}

/** One monitor pass: offline flips, then alerts. Reads /live once (D48). */
export async function runMonitorPass(
  nowMs = Date.now(),
): Promise<{ flipped: string[]; alerts: AlertPassResult | null }> {
  const live = await readAllLive();
  const flipped: string[] = [];
  for (const [id, l] of live) {
    if (!l.online || !isStale(l.lastSeen, nowMs, l.heartbeatS)) continue;
    try {
      const since = await flipOfflineIfStale(id, nowMs);
      if (since === null) continue;
      flipped.push(id);
      live.set(id, { ...l, online: false } satisfies Live);
      await openOfflineProblem(id, since);
    } catch (e) {
      await logError({ source: SOURCE, code: "INTERNAL", message: String(e), deviceId: id });
    }
  }
  if (flipped.length > 0) {
    console.log(
      JSON.stringify({ severity: "INFO", event: "devices_offline", count: flipped.length }),
    );
  }

  let alerts: AlertPassResult | null = null;
  try {
    alerts = await runAlertPass(nowMs, live);
  } catch (e) {
    await logError({ source: SOURCE, code: "INTERNAL", message: `alerts: ${String(e)}` });
  }
  return { flipped, alerts };
}

export const monitorDevices = onSchedule(
  {
    schedule: "every 1 minutes",
    timeZone: TIME_ZONE,
    secrets: ALERT_SECRETS,
  },
  async () => {
    await runMonitorPass();
  },
);
