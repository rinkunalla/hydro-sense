import { onSchedule } from "firebase-functions/scheduler";
import { OFFLINE_AFTER_S, TIME_ZONE } from "../config";
import { C, db, ms, ts } from "../lib/db";
import { isStale } from "../lib/decisions";
import { logError } from "../lib/logError";

/**
 * Flips one device offline only if a fresh read inside the transaction still
 * shows it stale, so an ingest landing at the same moment wins (CLAUDE.md D18).
 */
export async function flipOfflineIfStale(deviceId: string, nowMs: number): Promise<boolean> {
  const ref = db.collection(C.deviceHealth).doc(deviceId);
  return db.runTransaction(async (tx) => {
    const health = await tx.get(ref);
    if (health.get("online") !== true || !isStale(ms(health.get("lastSeen")), nowMs)) return false;
    tx.update(ref, { online: false });
    return true;
  });
}

/** One monitor pass. Phase 2: online flags only; alerts and the summary call arrive in Phase 3. */
export async function runMonitorPass(nowMs = Date.now()): Promise<{ flipped: string[] }> {
  const candidates = await db
    .collection(C.deviceHealth)
    .where("online", "==", true)
    .where("lastSeen", "<=", ts(nowMs - OFFLINE_AFTER_S * 1000))
    .get();

  const flipped: string[] = [];
  for (const doc of candidates.docs) {
    try {
      if (await flipOfflineIfStale(doc.id, nowMs)) flipped.push(doc.id);
    } catch (e) {
      await logError({
        source: "monitorDevices",
        code: "INTERNAL",
        message: String(e),
        deviceId: doc.id,
      });
    }
  }
  if (flipped.length > 0) {
    console.log(
      JSON.stringify({ severity: "INFO", event: "devices_offline", count: flipped.length }),
    );
  }
  return { flipped };
}

export const monitorDevices = onSchedule(
  { schedule: "every 1 minutes", timeZone: TIME_ZONE },
  async () => {
    await runMonitorPass();
  },
);
