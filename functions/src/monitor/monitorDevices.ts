import { onSchedule } from "firebase-functions/scheduler";
import { runAlertPass, type AlertPassResult } from "../alerts/alertPass";
import { OFFLINE_AFTER_MIN_S, TIME_ZONE } from "../config";
import { C, db, ms, ts } from "../lib/db";
import { isStale } from "../lib/decisions";
import { logError } from "../lib/logError";
import { ALERT_SECRETS } from "../lib/providers";

const SOURCE = "monitorDevices";

/**
 * Flips one device offline only if a fresh read inside the transaction still
 * shows it stale, so an ingest landing at the same moment wins (CLAUDE.md D18).
 */
export async function flipOfflineIfStale(deviceId: string, nowMs: number): Promise<boolean> {
  const ref = db.collection(C.deviceHealth).doc(deviceId);
  return db.runTransaction(async (tx) => {
    const health = await tx.get(ref);
    const hb = health.get("heartbeatS");
    const heartbeatS = typeof hb === "number" ? hb : null;
    if (health.get("online") !== true || !isStale(ms(health.get("lastSeen")), nowMs, heartbeatS)) {
      return false;
    }
    tx.update(ref, { online: false });
    return true;
  });
}

/** One monitor pass: offline flips, then alerts. */
export async function runMonitorPass(
  nowMs = Date.now(),
): Promise<{ flipped: string[]; alerts: AlertPassResult | null }> {
  const candidates = await db
    .collection(C.deviceHealth)
    .where("online", "==", true)
    // The shortest possible threshold; each device's own is checked in the flip.
    .where("lastSeen", "<=", ts(nowMs - OFFLINE_AFTER_MIN_S * 1000))
    .get();

  const flipped: string[] = [];
  for (const doc of candidates.docs) {
    try {
      if (await flipOfflineIfStale(doc.id, nowMs)) flipped.push(doc.id);
    } catch (e) {
      await logError({ source: SOURCE, code: "INTERNAL", message: String(e), deviceId: doc.id });
    }
  }
  if (flipped.length > 0) {
    console.log(
      JSON.stringify({ severity: "INFO", event: "devices_offline", count: flipped.length }),
    );
  }

  let alerts: AlertPassResult | null = null;
  try {
    alerts = await runAlertPass(nowMs);
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
