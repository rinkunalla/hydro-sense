import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

if (getApps().length === 0) initializeApp();

export const db = getFirestore();

// Collection names (CLAUDE.md section 4).
export const C = {
  config: "config",
  users: "users",
  devices: "devices",
  flowLogs: "flow_logs",
  deviceHealth: "device_health",
  batteryLogs: "battery_logs",
  deviceSecrets: "device_secrets",
  allowedDevices: "allowed_devices",
  removedDevices: "removed_devices",
  alertState: "alert_state",
  alertDaily: "alert_daily",
  aiInsights: "ai_insights",
  errorLogs: "error_logs",
  rateLimits: "rate_limits",
} as const;

export const ms = (t: unknown): number | null => (t instanceof Timestamp ? t.toMillis() : null);

export const ts = (millis: number) => Timestamp.fromMillis(millis);
