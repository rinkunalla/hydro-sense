import { onSchedule } from "firebase-functions/scheduler";
import { mirrorDevice } from "../lib/liveStore";
import {
  CALIBRATE_BUCKET_S,
  CALIBRATE_SCHEDULE,
  CALIBRATE_SKIP_AFTER_ALERT_H,
  CALIBRATE_WINDOW_H,
  TIME_ZONE,
} from "../config";
import { purgeExpired } from "../admin/purge";
import { alertStateRef } from "../alerts/alertPass";
import { bucketAverages, enoughData, fallbackCutoffs, flowStats } from "../lib/calibrationMath";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";

const SOURCE = "calibrateFlowThresholdsWeekly";
const HOUR_MS = 3_600_000;

export type CalibrationResult = "updated" | "kept_insufficient" | "kept_recent_alert";

export async function calibrateDevice(deviceId: string, nowMs: number): Promise<CalibrationResult> {
  const flowState = await alertStateRef(deviceId, "flow").get();
  const lastAlertMs = ms(flowState.get("lastSentAt"));
  if (lastAlertMs !== null && nowMs - lastAlertMs < CALIBRATE_SKIP_AFTER_ALERT_H * HOUR_MS) {
    return "kept_recent_alert";
  }

  const rows = await db
    .collection(C.devices)
    .doc(deviceId)
    .collection(C.flowLogs)
    .where("flowStatus", "!=", "No Flow")
    .where("ts", ">=", ts(nowMs - CALIBRATE_WINDOW_H * HOUR_MS))
    .get();
  const stats = flowStats(
    bucketAverages(
      rows.docs.map((d) => ({ tsMs: ms(d.get("ts")) ?? 0, flowRate: d.get("flowRate") as number })),
      CALIBRATE_BUCKET_S,
    ),
  );
  if (!enoughData(stats)) return "kept_insufficient";

  const cutoffs = fallbackCutoffs(stats.mean);
  await db
    .collection(C.devices)
    .doc(deviceId)
    .update({ ...cutoffs, calibratedAt: ts(nowMs) });
  await mirrorDevice(deviceId); // reaches the device in its next upload reply
  return "updated";
}

/** Every assigned device that is not removed (CLAUDE.md section 6). */
export async function calibrateAll(nowMs = Date.now()) {
  const devices = await db.collection(C.devices).where("ownerUid", "!=", null).get();
  const results: { deviceId: string; result: CalibrationResult }[] = [];
  for (const d of devices.docs) {
    if (d.get("removedAt")) continue;
    try {
      results.push({ deviceId: d.id, result: await calibrateDevice(d.id, nowMs) });
    } catch (e) {
      await logError({
        source: SOURCE,
        code: "INTERNAL",
        message: String(e),
        deviceId: d.id,
        nowMs,
      });
    }
  }
  return results;
}

export const calibrateFlowThresholdsWeekly = onSchedule(
  { schedule: CALIBRATE_SCHEDULE, timeZone: TIME_ZONE },
  async () => {
    // Purge first (D42), so a purged device is never calibrated.
    await purgeExpired();
    await calibrateAll();
  },
);
