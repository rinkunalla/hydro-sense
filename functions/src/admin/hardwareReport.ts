import { HttpsError, onCall } from "firebase-functions/https";
import { onSchedule } from "firebase-functions/scheduler";
import {
  ADMIN_REPORT_COOLDOWN_S,
  ADMIN_REPORT_ERROR_WINDOW_H,
  ADMIN_REPORT_MAX_CHARS,
  ADMIN_REPORT_SCHEDULE,
  TIME_ZONE,
} from "../config";
import { requireAdmin } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { MODEL_SECRETS, providers } from "../lib/providers";

const SOURCE = "generateAdminHardwareReport";
const HOUR_MS = 3_600_000;
const REPORT = () => db.collection(C.aiInsights).doc("admin_diagnostics");

interface DeviceHealthLine {
  id: string;
  online: boolean;
  lastSeenAgoMin: number | null;
  batteryVoltage: number | null;
  batteryPercent: number | null;
  chargingStatus: string | null;
  batteryFault: boolean;
  lowVoltageSleep: boolean;
  minVoltage24h: number | null;
  firmware: string | null;
  rssi: number | null;
}

/**
 * Reads ONLY device_health (with battery_logs) and error_logs. Admin privacy
 * (CLAUDE.md section 4): never devices, flow_logs, nicknames or locations.
 */
export async function collectHardwareFacts(nowMs: number) {
  const since = ts(nowMs - ADMIN_REPORT_ERROR_WINDOW_H * HOUR_MS);
  const [health, errors] = await Promise.all([
    db.collection(C.deviceHealth).get(),
    db.collection(C.errorLogs).where("ts", ">=", since).get(),
  ]);

  const devices: DeviceHealthLine[] = [];
  for (const d of health.docs) {
    const logs = await d.ref.collection(C.batteryLogs).where("ts", ">=", since).get();
    const volts = logs.docs
      .map((l) => l.get("batteryVoltage") as number | null)
      .filter((v): v is number => typeof v === "number");
    const lastSeen = ms(d.get("lastSeen"));
    devices.push({
      id: d.id,
      online: d.get("online") === true,
      lastSeenAgoMin: lastSeen === null ? null : Math.round((nowMs - lastSeen) / 60000),
      batteryVoltage: d.get("batteryVoltage") ?? null,
      batteryPercent: d.get("batteryPercent") ?? null,
      chargingStatus: d.get("chargingStatus") ?? null,
      batteryFault: d.get("batteryFault") === true,
      lowVoltageSleep: d.get("lowVoltageSleep") === true,
      minVoltage24h: volts.length > 0 ? Math.min(...volts) : null,
      firmware: d.get("firmware") ?? null,
      rssi: d.get("rssi") ?? null,
    });
  }

  const errorCounts: Record<string, number> = {};
  for (const e of errors.docs) {
    const key = `${e.get("deviceId") ?? "system"} ${e.get("code")}`;
    errorCounts[key] = (errorCounts[key] ?? 0) + 1;
  }
  return { devices, errorCounts };
}

const SYSTEM =
  "You write a short hardware health report for the admin of a water-monitoring system. Use at " +
  "most 6 short sentences in plain text. Mention offline devices, low or falling batteries, " +
  "battery faults, low-voltage sleep, weak signal (rssi below -80) and repeated errors, most " +
  "urgent first. If everything is healthy, say so in one sentence. Use only the data given.";

export function fallbackReport(facts: Awaited<ReturnType<typeof collectHardwareFacts>>): string {
  const d = facts.devices;
  if (d.length === 0) return "No devices have registered yet.";
  const offline = d.filter((x) => !x.online).map((x) => x.id);
  const low = d.filter((x) => (x.batteryPercent ?? 100) < 20).map((x) => x.id);
  const parts = [`${d.length} devices registered, ${d.length - offline.length} online.`];
  if (offline.length) parts.push(`Offline: ${offline.join(", ")}.`);
  if (low.length) parts.push(`Low battery: ${low.join(", ")}.`);
  const errs = Object.keys(facts.errorCounts).length;
  if (errs) parts.push(`${errs} error types logged in the last 24 hours.`);
  return parts.join(" ");
}

export async function generateReport(nowMs = Date.now()): Promise<{ text: string; ai: boolean }> {
  const facts = await collectHardwareFacts(nowMs);
  let text: string;
  let ai = true;
  try {
    const raw = await providers().model.generate({
      system: SYSTEM,
      prompt: JSON.stringify(facts),
    });
    text = raw.trim().slice(0, ADMIN_REPORT_MAX_CHARS);
    if (!text) throw new Error("empty");
  } catch (e) {
    await logError({ source: SOURCE, code: "AI_FAILED", message: String(e), nowMs });
    text = fallbackReport(facts);
    ai = false;
  }
  await REPORT().set({ text, lastUpdated: ts(nowMs) }, { merge: true });
  return { text, ai };
}

export const generateAdminHardwareReportDaily = onSchedule(
  { schedule: ADMIN_REPORT_SCHEDULE, timeZone: TIME_ZONE, secrets: MODEL_SECRETS },
  async () => {
    await generateReport();
  },
);

export const generateAdminHardwareReport = onCall({ secrets: MODEL_SECRETS }, async (request) => {
  requireAdmin(request);
  const nowMs = Date.now();
  const waitMs = await db.runTransaction(async (tx) => {
    const last = ms((await tx.get(REPORT())).get("lastAttemptAt"));
    const wait = last === null ? 0 : last + ADMIN_REPORT_COOLDOWN_S * 1000 - nowMs;
    if (wait <= 0) tx.set(REPORT(), { lastAttemptAt: ts(nowMs) }, { merge: true });
    return wait;
  });
  if (waitMs > 0) {
    throw new HttpsError("resource-exhausted", "Report cooldown.", {
      code: "COOLDOWN",
      retryAfterSeconds: Math.ceil(waitMs / 1000),
    });
  }
  const r = await generateReport(nowMs);
  return { text: r.text, lastUpdated: nowMs };
});
