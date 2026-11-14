import type { Response } from "express";

export type DeviceErrorCode =
  | "PAYLOAD_INVALID"
  | "PROVISIONING_KEY_INVALID"
  | "DEVICE_AUTH_FAILED"
  | "DEVICE_NOT_ALLOWED"
  | "DEVICE_ACTIVE"
  | "REGISTER_RATE_LIMITED"
  | "INTERNAL";

const STATUS: Record<DeviceErrorCode, number> = {
  PAYLOAD_INVALID: 400,
  PROVISIONING_KEY_INVALID: 401,
  DEVICE_AUTH_FAILED: 401,
  DEVICE_NOT_ALLOWED: 403,
  DEVICE_ACTIVE: 409,
  REGISTER_RATE_LIMITED: 429,
  INTERNAL: 500,
};

/** Standard device-endpoint error shape (docs/ERROR_HANDLING.md section 2). */
export function sendError(res: Response, code: DeviceErrorCode, message: string): void {
  res.status(STATUS[code]).json({ ok: false, code, message });
}

export function sendOk(res: Response, body: Record<string, unknown>): void {
  res.status(200).json({ ok: true, ...body });
}

export function header(req: { get(name: string): string | undefined }, name: string) {
  const v = req.get(name);
  return typeof v === "string" && v.length > 0 ? v : null;
}

export function bearerToken(req: { get(name: string): string | undefined }): string | null {
  const auth = header(req, "Authorization");
  const match = auth?.match(/^Bearer (\S+)$/);
  return match?.[1] ?? null;
}
