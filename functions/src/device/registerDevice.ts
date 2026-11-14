import { onRequest } from "firebase-functions/https";
import { defineSecret } from "firebase-functions/params";
import {
  REGISTER_MAX_PER_HOUR,
  STARTER_LOW_FLOW_CUTOFF,
  STARTER_NORMAL_FLOW_CUTOFF,
} from "../config";
import { effectiveCutoffs } from "../lib/cutoffs";
import { C, db, ts } from "../lib/db";
import { newDeviceDoc, newHealthDoc } from "../lib/deviceDocs";
import { header, sendError, sendOk } from "../lib/http";
import { logError } from "../lib/logError";
import { parseRegisterBody } from "../lib/payload";
import { generateToken, safeEqual, sha256Hex } from "../lib/tokens";

export const PROVISIONING_KEY = defineSecret("PROVISIONING_KEY");

type Outcome =
  | { kind: "ok"; token: string; lowFlowCutoff: number; normalFlowCutoff: number; created: boolean }
  | { kind: "not_allowed" | "active" | "rate_limited" };

const HOUR_MS = 3_600_000;

async function register(deviceId: string, firmware: string | null, nowMs: number) {
  const token = generateToken();
  const hour = Math.floor(nowMs / HOUR_MS);

  return db.runTransaction<Outcome>(async (tx) => {
    const rateRef = db.collection(C.rateLimits).doc(`register__${hour}`);
    const [rate, allowed, device, health] = await Promise.all([
      tx.get(rateRef),
      tx.get(db.collection(C.allowedDevices).doc(deviceId)),
      tx.get(db.collection(C.devices).doc(deviceId)),
      tx.get(db.collection(C.deviceHealth).doc(deviceId)),
    ]);

    const count = (rate.get("count") as number | undefined) ?? 0;
    if (count >= REGISTER_MAX_PER_HOUR) return { kind: "rate_limited" };
    tx.set(rateRef, { count: count + 1, expireAt: ts(nowMs + 2 * HOUR_MS) });

    if (!allowed.exists) return { kind: "not_allowed" };
    if (device.exists && health.get("online") === true) return { kind: "active" };

    const now = ts(nowMs);
    tx.set(db.collection(C.deviceSecrets).doc(deviceId), {
      tokenHash: sha256Hex(token),
      issuedAt: now,
    });

    if (device.exists) {
      // Records made by assignDevice before the first registration keep their owner
      // and nickname; only the registration time and firmware are filled in (D41).
      tx.set(
        db.collection(C.deviceHealth).doc(deviceId),
        {
          firmware: firmware ?? health.get("firmware") ?? null,
          ...(health.get("registeredAt") ? {} : { registeredAt: now }),
        },
        { merge: true },
      );
      return {
        kind: "ok",
        token,
        created: false,
        ...effectiveCutoffs((f) => device.get(f)),
      };
    }

    // A device never assigned registers unassigned; the admin assigns it (D10 superseded).
    tx.create(db.collection(C.devices).doc(deviceId), newDeviceDoc(deviceId, null, now));
    tx.create(db.collection(C.deviceHealth).doc(deviceId), newHealthDoc(null, now, firmware));
    return {
      kind: "ok",
      token,
      created: true,
      lowFlowCutoff: STARTER_LOW_FLOW_CUTOFF,
      normalFlowCutoff: STARTER_NORMAL_FLOW_CUTOFF,
    };
  });
}

export const registerDevice = onRequest(
  { invoker: "public", secrets: [PROVISIONING_KEY] },
  async (req, res) => {
    const source = "registerDevice";
    if (req.method !== "POST") return sendError(res, "PAYLOAD_INVALID", "Use POST.");

    const key = header(req, "X-Provisioning-Key");
    if (key === null || !safeEqual(key, PROVISIONING_KEY.value())) {
      // No deviceId: the body is untrusted, and random IDs would defeat the dedupe.
      await logError({ source, code: "PROVISIONING_KEY_INVALID", message: "Bad or missing key" });
      return sendError(res, "PROVISIONING_KEY_INVALID", "Provisioning key rejected.");
    }

    const parsed = parseRegisterBody(req.body);
    if (!parsed.ok) return sendError(res, "PAYLOAD_INVALID", parsed.error);
    const { deviceId, firmware } = parsed.value;

    try {
      const out = await register(deviceId, firmware, Date.now());
      switch (out.kind) {
        case "ok":
          console.log(JSON.stringify({ severity: "INFO", event: "device_registered", deviceId }));
          return sendOk(res, {
            token: out.token,
            lowFlowCutoff: out.lowFlowCutoff,
            normalFlowCutoff: out.normalFlowCutoff,
          });
        case "not_allowed":
          return sendError(res, "DEVICE_NOT_ALLOWED", "This device ID is not on the allowlist.");
        case "active":
          return sendError(res, "DEVICE_ACTIVE", "Device is online; re-registration refused.");
        case "rate_limited":
          await logError({ source, code: "REGISTER_RATE_LIMITED", message: "Hourly limit hit" });
          return sendError(res, "REGISTER_RATE_LIMITED", "Too many registrations. Retry later.");
      }
    } catch (e) {
      await logError({ source, code: "INTERNAL", message: String(e), deviceId });
      return sendError(res, "INTERNAL", "Internal error.");
    }
  },
);
