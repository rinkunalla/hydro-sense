// Pure validation of admin input. Each parser throws
// an HttpsError with a stable code the website maps to its own wording.
import { HttpsError } from "firebase-functions/https";
import {
  MIN_PASSWORD_LENGTH,
  NICKNAME_MAX,
  PASSWORD_MAX_LENGTH,
  PH_MOBILE_PATTERN,
  STAFF_LOGIN_DOMAIN,
  USER_NAME_MAX,
  USERNAME_MAX,
  USERNAME_MIN,
} from "../config";
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

/** An optional contact: undefined = unchanged, null or "" = none. */
export function parseOptionalPhone(v: unknown): string | null | undefined {
  if (v === undefined) return undefined;
  if (v === null || (typeof v === "string" && v.trim() === "")) return null;
  return parsePhone(v);
}

export function parseOptionalEmail(v: unknown): string | null | undefined {
  if (v === undefined) return undefined;
  if (v === null || (typeof v === "string" && v.trim() === "")) return null;
  return parseEmail(v);
}

/** A device name: 1 to NICKNAME_MAX characters after trimming. */
export function parseDeviceName(v: unknown): string {
  const name = typeof v === "string" ? v.trim().replace(/\s+/g, " ") : "";
  if (name.length < 1 || name.length > NICKNAME_MAX) {
    throw invalid("NAME_INVALID", `Name must be 1 to ${NICKNAME_MAX} characters.`);
  }
  return name;
}

export function parsePassword(v: unknown): string {
  if (typeof v !== "string" || v.length < MIN_PASSWORD_LENGTH || v.length > PASSWORD_MAX_LENGTH) {
    throw invalid("PASSWORD_WEAK", `Use at least ${MIN_PASSWORD_LENGTH} characters.`);
  }
  return v;
}

/**
 * A staff username (D64): what staff type on the app's Sign in screen.
 * Returns the stored form, or throws USERNAME_INVALID.
 * USERNAME_MIN and USERNAME_MAX bound the length.
 */
export function parseUsername(v: unknown): string {
  const username = typeof v === "string" ? v.trim().toLowerCase() : "";
  if (username.length < USERNAME_MIN || username.length > USERNAME_MAX) {
    throw invalid("USERNAME_INVALID", `Use ${USERNAME_MIN} to ${USERNAME_MAX} characters.`);
  }
  // Each allowed character is also valid before the @ of the hidden sign-in
  // address; a dot may not start or end it or come twice in a row.
  if (!/^[a-z0-9._-]+$/.test(username) || /^\.|\.$|\.\./.test(username)) {
    throw invalid(
      "USERNAME_INVALID",
      "Use letters, numbers, dots, dashes or underscores, with no spaces.",
    );
  }
  return username;
}

/** The hidden Firebase Auth address behind a username. */
export const staffLoginEmail = (username: string) => `${username}@${STAFF_LOGIN_DOMAIN}`;

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
