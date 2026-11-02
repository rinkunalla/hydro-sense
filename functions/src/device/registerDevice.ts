import { onRequest } from "firebase-functions/https";
import { defineSecret } from "firebase-functions/params";
import {
  REGISTER_MAX_PER_HOUR,
  STARTER_LOW_FLOW_CUTOFF,
  STARTER_NORMAL_FLOW_CUTOFF,
} from "../config";
import { C, db, ts } from "../lib/db";
import { header, sendError, sendOk } from "../lib/http";
import { logError } from "../lib/logError";
import { parseRegisterBody } from "../lib/payload";
import { generateToken, safeEqual, sha256Hex } from "../lib/tokens";

export const PROVISIONING_KEY = defineSecret("PROVISIONING_KEY");

type Outcome =
  | { kind: "ok"; token: string; lowFlowCutoff: number; normalFlowCutoff: number; created: boolean }
  | { kind: "removed" | "not_allowed" | "active" | "rate_limited" };

const HOUR_MS = 3_600_000;

async function register(deviceId: string, firmware: string | null, nowMs: number) {
  const token = generateToken();
  const hour = Math.floor(nowMs / HOUR_MS);

  return db.runTransaction<Outcome>(async (tx) => {
    const rateRef = db.collection(C.rateLimits).doc(`register__${hour}`);
    const [rate, removed, allowed, device, health, system] = await Promise.all([
      tx.get(rateRef),
      tx.get(db.collection(C.removedDevices).doc(deviceId)),
      tx.get(db.collection(C.allowedDevices).doc(deviceId)),
      tx.get(db.collection(C.devices).doc(deviceId)),
      tx.get(db.collection(C.deviceHealth).doc(deviceId)),
      tx.get(db.collection(C.config).doc("system")),
    ]);

    const count = (rate.get("count") as number | undefined) ?? 0;
    if (count >= REGISTER_MAX_PER_HOUR) return { kind: "rate_limited" };
    tx.set(rateRef, { count: count + 1, expireAt: ts(nowMs + 2 * HOUR_MS) });

    if (removed.exists) return { kind: "removed" };
    if (!allowed.exists) return { kind: "not_allowed" };
    if (device.exists && health.get("online") === true) return { kind: "active" };

    const now = ts(nowMs);
    tx.set(db.collection(C.deviceSecrets).doc(deviceId), {
      tokenHash: sha256Hex(token),
      issuedAt: now,
    });

    if (device.exists) {
      tx.set(
        db.collection(C.deviceHealth).doc(deviceId),
        { firmware: firmware ?? health.get("firmware") ?? null },
        { merge: true },
      );
      return {
        kind: "ok",
        token,
        created: false,
        lowFlowCutoff: (device.get("lowFlowCutoff") as number) ?? STARTER_LOW_FLOW_CUTOFF,
        normalFlowCutoff: (device.get("normalFlowCutoff") as number) ?? STARTER_NORMAL_FLOW_CUTOFF,
      };
    }

    const ownerUid = (system.get("clientUid") as string | undefined) ?? null;
    tx.create(db.collection(C.devices).doc(deviceId), {
      ownerUid,
      nickname: `Device ${deviceId.slice(-4)}`,
      flowStatus: null,
      flowRate: null,
      lat: null,
      lng: null,
      lowFlowCutoff: STARTER_LOW_FLOW_CUTOFF,
      normalFlowCutoff: STARTER_NORMAL_FLOW_CUTOFF,
      calibratedAt: null,
      abnormalSince: null,
      statusChangedAt: null,
      pausedUntil: null,
      updatedAt: now,
    });
    tx.create(db.collection(C.deviceHealth).doc(deviceId), {
      ownerUid,
      online: false,
      lastSeen: null,
      batteryVoltage: null,
      batteryPercent: null,
      chargingStatus: null,
      recentVoltages: [],
      batteryFault: false,
      lowVoltageSleep: false,
      lastBatteryLogAt: null,
      lastFlowLogAt: null,
      resetReason: null,
      registeredAt: now,
      firmware,
      rssi: null,
    });
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
        case "removed":
          return sendError(res, "DEVICE_REMOVED", "This device was removed by the admin.");
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
