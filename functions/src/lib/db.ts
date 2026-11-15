import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

if (getApps().length === 0) initializeApp();

export const db = getFirestore();

// Collection names (CLAUDE.md section 4).
export const C = {
  users: "users",
  admins: "admins",
  adminAudit: "admin_audit",
  phoneIndex: "phone_index",
  pipelines: "pipelines",
  pushTokens: "push_tokens",
  passwordResets: "password_resets",
  adminSetupTokens: "admin_setup_tokens",
  devices: "devices",
  flowLogs: "flow_logs",
  deviceHealth: "device_health",
  deviceSecrets: "device_secrets",
  allowedDevices: "allowed_devices",
  alertState: "alert_state",
  alertDaily: "alert_daily",
  errorLogs: "error_logs",
  rateLimits: "rate_limits",
  settings: "settings",
} as const;

export const ms = (t: unknown): number | null => (t instanceof Timestamp ? t.toMillis() : null);

export const ts = (millis: number) => Timestamp.fromMillis(millis);
