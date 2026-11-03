import { HttpsError, onCall } from "firebase-functions/https";
import { onSchedule } from "firebase-functions/scheduler";
import {
  CALIBRATE_BUCKET_S,
  CALIBRATE_LOW_MIN,
  CALIBRATE_NORMAL_MAX_OF_MEAN,
  CALIBRATE_NORMAL_MIN,
  CALIBRATE_SCHEDULE,
  CALIBRATE_SKIP_AFTER_ALERT_H,
  CALIBRATE_WINDOW_H,
  CLIENT_CALIBRATE_COOLDOWN_S,
  TIME_ZONE,
} from "../config";
import { alertStateRef } from "../alerts/alertPass";
import { requireClient } from "../lib/auth";
import {
  CUTOFF_SCHEMA,
  bucketAverages,
  enoughData,
  fallbackCutoffs,
  flowStats,
  parseModelCutoffs,
  validCutoffs,
  type Cutoffs,
  type FlowStats,
} from "../lib/calibrationMath";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { MODEL_SECRETS, providers } from "../lib/providers";

const SOURCE = "calibrateFlowThresholds";
const HOUR_MS = 3_600_000;

export type CalibrationResult = "updated" | "kept_insufficient" | "kept_recent_alert";

const SYSTEM =
  "You set flow thresholds for one water line. Reply with JSON only. lowFlowCutoff: below it the " +
  "line counts as No Flow. normalFlowCutoff: below it the line counts as Low Flow. Both in L/min.";

const prompt = (s: FlowStats) =>
  `Last 24 h, 5-minute averages with No Flow excluded: samples ${s.samples}, mean ` +
  `${s.mean.toFixed(2)}, p10 ${s.p10.toFixed(2)}, p50 ${s.p50.toFixed(2)} L/min. ` +
  `Rules: ${CALIBRATE_LOW_MIN} <= lowFlowCutoff < normalFlowCutoff; ${CALIBRATE_NORMAL_MIN} <= ` +
  `normalFlowCutoff <= ${(CALIBRATE_NORMAL_MAX_OF_MEAN * s.mean).toFixed(2)}.`;

async function proposeCutoffs(deviceId: string, s: FlowStats, nowMs: number): Promise<Cutoffs> {
  try {
    const text = await providers().model.generate({
      system: SYSTEM,
      prompt: prompt(s),
      jsonSchema: CUTOFF_SCHEMA,
    });
    const c = parseModelCutoffs(text);
    if (c && validCutoffs(c, s.mean)) return c;
    await logError({
      source: SOURCE,
      code: "AI_INVALID_OUTPUT",
      message: "Cutoffs failed validation",
      deviceId,
      nowMs,
    });
  } catch (e) {
    await logError({ source: SOURCE, code: "AI_FAILED", message: String(e), deviceId, nowMs });
  }
  await logError({
    source: SOURCE,
    code: "CALIBRATION_FALLBACK",
    message: "Deterministic cutoffs used",
    deviceId,
    nowMs,
  });
  return fallbackCutoffs(s.mean);
}

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

  const cutoffs = await proposeCutoffs(deviceId, stats, nowMs);
  await db
    .collection(C.devices)
    .doc(deviceId)
    .update({ ...cutoffs, calibratedAt: ts(nowMs) });
  return "updated";
}

export async function calibrateAll(nowMs = Date.now()) {
  const system = await db.collection(C.config).doc("system").get();
  const clientUid = system.get("clientUid") as string | undefined;
  if (!clientUid) return [];
  const devices = await db.collection(C.devices).where("ownerUid", "==", clientUid).get();
  const results: { deviceId: string; nickname: string; result: CalibrationResult }[] = [];
  for (const d of devices.docs) {
    try {
      results.push({
        deviceId: d.id,
        nickname: d.get("nickname"),
        result: await calibrateDevice(d.id, nowMs),
      });
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
  { schedule: CALIBRATE_SCHEDULE, timeZone: TIME_ZONE, secrets: MODEL_SECRETS },
  async () => {
    await calibrateAll();
  },
);

export const calibrateFlowThresholds = onCall({ secrets: MODEL_SECRETS }, async (request) => {
  const uid = requireClient(request);
  const nowMs = Date.now();
  const userRef = db.collection(C.users).doc(uid);
  const waitMs = await db.runTransaction(async (tx) => {
    const last = ms((await tx.get(userRef)).get("lastCalibrateAt"));
    const wait = last === null ? 0 : last + CLIENT_CALIBRATE_COOLDOWN_S * 1000 - nowMs;
    if (wait <= 0) tx.set(userRef, { lastCalibrateAt: ts(nowMs) }, { merge: true });
    return wait;
  });
  if (waitMs > 0) {
    throw new HttpsError("resource-exhausted", "Calibration cooldown.", {
      code: "COOLDOWN",
      retryAfterSeconds: Math.ceil(waitMs / 1000),
    });
  }
  return { results: await calibrateAll(nowMs) };
});
