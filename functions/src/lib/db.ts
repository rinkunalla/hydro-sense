import { getApps, initializeApp } from "firebase-admin/app";
import { getDatabaseWithUrl } from "firebase-admin/database";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { DATABASE_URL } from "../config";

if (getApps().length === 0) initializeApp();

export const db = getFirestore();

/** Realtime Database: the live channel (D48). The emulator is used when
 * FIREBASE_DATABASE_EMULATOR_HOST is set. */
export const rtdb = getDatabaseWithUrl(DATABASE_URL);
export const liveRef = (id: string) => rtdb.ref(`live/${id}`);
export const stateRef = (id: string) => rtdb.ref(`state/${id}`);

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
  problems: "problems",
  readings: "readings",
} as const;

export const ms = (t: unknown): number | null => (t instanceof Timestamp ? t.toMillis() : null);

export const ts = (millis: number) => Timestamp.fromMillis(millis);
