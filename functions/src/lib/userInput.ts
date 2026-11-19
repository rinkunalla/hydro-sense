// Pure validation of admin input. Each parser throws
// an HttpsError with a stable code the website maps to its own wording.
import { HttpsError } from "firebase-functions/https";
import { LABEL_MAX, PH_MOBILE_PATTERN, USER_NAME_MAX } from "../config";
import { normalizeDeviceId } from "./payload";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const invalid = (code: string, message: string) =>
  new HttpsError("invalid-argument", message, { code });

/** 09XXXXXXXXX, +639XXXXXXXXX or 639XXXXXXXXX -> 639XXXXXXXXX, else null. */
export function normalizePhMobile(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const m = PH_MOBILE_PATTERN.exec(input.replace(/[\s-]/g, ""));
  return m ? `639${m[1]}` : null;
}

/** Firebase Auth wants E.164. */
export const e164 = (phone: string) => `+${phone}`;

export function parseName(v: unknown): string {
  const name = typeof v === "string" ? v.trim().replace(/\s+/g, " ") : "";
  if (name.length < 1 || name.length > USER_NAME_MAX) {
    throw invalid("NAME_INVALID", `Name must be 1 to ${USER_NAME_MAX} characters.`);
  }
  return name;
}

export function parseEmail(v: unknown): string {
  const email = typeof v === "string" ? v.trim().toLowerCase() : "";
  if (!EMAIL_PATTERN.test(email) || email.length > 254) {
    throw invalid("EMAIL_INVALID", "Enter a valid email address.");
  }
  return email;
}

export function parsePhone(v: unknown): string {
  const phone = normalizePhMobile(v);
  if (!phone) throw invalid("PHONE_INVALID", "Enter a Philippine mobile number.");
  return phone;
}

/** null clears the label; otherwise 1 to LABEL_MAX characters after trimming. */
export function parseLabel(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  const label = typeof v === "string" ? v.trim() : "";
  if (label === "") return null;
  if (label.length > LABEL_MAX) {
    throw invalid("LABEL_INVALID", `Label must be at most ${LABEL_MAX} characters.`);
  }
  return label;
}

export function parseDeviceId(v: unknown): string {
  const id = normalizeDeviceId(v);
  if (!id) throw invalid("DEVICE_ID_INVALID", "Device ID must be 12 hex characters.");
  return id;
}

export function parseUid(v: unknown): string {
  if (typeof v !== "string" || v.length < 1 || v.length > 128) {
    throw invalid("USER_INVALID", "Choose a user.");
  }
  return v;
}

/**
 * Typed confirmation for destructive actions: case and surrounding spaces
 * do not matter, every other character does.
 */
export function confirmMatches(typed: unknown, expected: string): boolean {
  if (typeof typed !== "string") return false;
  const norm = (s: string) => s.trim().replace(/\s+/g, " ").toLowerCase();
  return norm(typed) === norm(expected) && norm(expected) !== "";
}

export const defaultNickname = (deviceId: string) => `Device ${deviceId.slice(-4)}`;
