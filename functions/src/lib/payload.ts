import { DEVICE_ID_PATTERN, FLOW_RATE_MAX } from "../config";

export const FLOW_STATUSES = ["Normal Flow", "Low Flow", "No Flow"] as const;
export type FlowStatus = (typeof FLOW_STATUSES)[number];

export const TRIGGERS = ["status_change", "rate_change", "heartbeat"] as const;
export type Trigger = (typeof TRIGGERS)[number];

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

export interface IngestPayload {
  flowStatus: FlowStatus;
  flowRate: number;
  batteryVoltage: number | null;
  batteryFault: boolean;
  lat: number | null;
  lng: number | null;
  gpsValid: boolean;
  rssi: number | null;
  firmware: string | null;
  resetReason: string | null;
  trigger: Trigger;
  lowVoltageSleep: boolean;
}

export interface RegisterBody {
  deviceId: string;
  firmware: string | null;
}

const MAX_PACK_VOLTAGE = 30;
const FIRMWARE_MAX = 32;
const RESET_REASON_MAX = 64;

class Invalid extends Error {}

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

function finite(v: unknown, field: string): number {
  if (typeof v !== "number" || !Number.isFinite(v)) throw new Invalid(`${field} must be a number`);
  return v;
}

function optionalFinite(v: unknown, field: string): number | null {
  return v === undefined || v === null ? null : finite(v, field);
}

function optionalBool(v: unknown, field: string): boolean {
  if (v === undefined || v === null) return false;
  if (typeof v !== "boolean") throw new Invalid(`${field} must be a boolean`);
  return v;
}

function optionalString(v: unknown, field: string, max: number): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new Invalid(`${field} must be a string`);
  const s = v.trim();
  if (s.length > max) throw new Invalid(`${field} is longer than ${max} characters`);
  return s.length === 0 ? null : s;
}

function oneOf<T extends string>(v: unknown, allowed: readonly T[], field: string): T {
  if (typeof v !== "string" || !(allowed as readonly string[]).includes(v)) {
    throw new Invalid(`${field} must be one of ${allowed.join(", ")}`);
  }
  return v as T;
}

const clamp = (v: number, min: number, max: number) => Math.min(max, Math.max(min, v));

function wrap<T>(fn: () => T): Parsed<T> {
  try {
    return { ok: true, value: fn() };
  } catch (e) {
    if (e instanceof Invalid) return { ok: false, error: e.message };
    throw e;
  }
}

/** Validates and clamps a deviceIngest body (CLAUDE.md section 6, Device protocol). */
export function parseIngestPayload(body: unknown): Parsed<IngestPayload> {
  return wrap(() => {
    if (!isObject(body)) throw new Invalid("body must be a JSON object");

    const flowStatus = oneOf(body.flowStatus, FLOW_STATUSES, "flowStatus");
    const trigger = oneOf(body.trigger, TRIGGERS, "trigger");

    const rawRate = finite(body.flowRate, "flowRate");
    if (rawRate < 0) throw new Invalid("flowRate must not be negative");
    const flowRate = clamp(rawRate, 0, FLOW_RATE_MAX);

    const batteryFault = optionalBool(body.batteryFault, "batteryFault");
    let batteryVoltage: number | null = null;
    if (!batteryFault) {
      batteryVoltage = finite(body.batteryVoltage, "batteryVoltage");
      if (batteryVoltage <= 0 || batteryVoltage > MAX_PACK_VOLTAGE) {
        throw new Invalid("batteryVoltage out of range");
      }
    }

    const gpsValid = optionalBool(body.gpsValid, "gpsValid");
    let lat: number | null = null;
    let lng: number | null = null;
    if (gpsValid) {
      lat = finite(body.lat, "lat");
      lng = finite(body.lng, "lng");
      if (Math.abs(lat) > 90 || Math.abs(lng) > 180) throw new Invalid("lat/lng out of range");
    }

    const rawRssi = optionalFinite(body.rssi, "rssi");
    const rssi = rawRssi === null ? null : Math.round(clamp(rawRssi, -127, 0));

    return {
      flowStatus,
      flowRate,
      batteryVoltage,
      batteryFault,
      lat,
      lng,
      gpsValid,
      rssi,
      firmware: optionalString(body.firmware, "firmware", FIRMWARE_MAX),
      resetReason: optionalString(body.resetReason, "resetReason", RESET_REASON_MAX),
      trigger,
      lowVoltageSleep: optionalBool(body.lowVoltageSleep, "lowVoltageSleep"),
    };
  });
}

/** Validates a registerDevice body. */
export function parseRegisterBody(body: unknown): Parsed<RegisterBody> {
  return wrap(() => {
    if (!isObject(body)) throw new Invalid("body must be a JSON object");
    if (typeof body.deviceId !== "string" || !DEVICE_ID_PATTERN.test(body.deviceId)) {
      throw new Invalid("deviceId must be 12 uppercase hex characters");
    }
    return {
      deviceId: body.deviceId,
      firmware: optionalString(body.firmware, "firmware", FIRMWARE_MAX),
    };
  });
}

/** Admin input: accepts lowercase and colon/dash separators, returns the canonical ID or null. */
export function normalizeDeviceId(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const id = input.replace(/[\s:-]/g, "").toUpperCase();
  return DEVICE_ID_PATTERN.test(id) ? id : null;
}
