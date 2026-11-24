import { onRequest } from "firebase-functions/https";
import { defineSecret } from "firebase-functions/params";
import { REGISTER_MAX_PER_HOUR } from "../config";
import { effectiveCutoffs } from "../lib/cutoffs";
import { uploadPace } from "../lib/decisions";
import { C, db, ts } from "../lib/db";
import { newDeviceDoc, newHealthDoc } from "../lib/deviceDocs";
import { mirrorDevice, readLive } from "../lib/liveStore";
import { header, sendError, sendOk } from "../lib/http";
import { logError } from "../lib/logError";
import { parseRegisterBody } from "../lib/payload";
import { sensorOf, sensorReply } from "../lib/sensors";
import { generateToken, safeEqual, sha256Hex } from "../lib/tokens";

export const PROVISIONING_KEY = defineSecret("PROVISIONING_KEY");

type Outcome =
  | {
      kind: "ok";
      token: string;
      lowFlowCutoff: number;
      normalFlowCutoff: number;
      reply: ReturnType<typeof sensorReply>;
      created: boolean;
    }
  | { kind: "not_allowed" | "active" | "rate_limited" };

const HOUR_MS = 3_600_000;

export async function register(deviceId: string, firmware: string | null, nowMs: number) {
  const token = generateToken();
  const hour = Math.floor(nowMs / HOUR_MS);
  // online lives in the Realtime Database; read before the transaction.
  const online = (await readLive(deviceId)).online;

  const out = await db.runTransaction<Outcome>(async (tx) => {
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
    if (device.exists && online) return { kind: "active" };

    const now = ts(nowMs);
    tx.set(db.collection(C.deviceSecrets).doc(deviceId), {
      tokenHash: sha256Hex(token),
      issuedAt: now,
    });

    if (device.exists) {
      // Records made when the admin added the ID keep their name and sensor;
      // only the registration time and firmware are filled in.
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
        reply: sensorReply(sensorOf(device.get("sensorType"))),
      };
    }

    // An ID listed before v3 without records: they are made now (YF-S201 by default).
    const sensorType = sensorOf(null);
    const doc = newDeviceDoc(deviceId, now, { sensorType });
    tx.create(db.collection(C.devices).doc(deviceId), doc);
    tx.create(db.collection(C.deviceHealth).doc(deviceId), newHealthDoc(now, firmware));
    return {
      kind: "ok",
      token,
      created: true,
      lowFlowCutoff: doc.lowFlowCutoff,
      normalFlowCutoff: doc.normalFlowCutoff,
      reply: sensorReply(sensorType),
    };
  });
  // The new token hash, sensor and cutoffs reach the live channel.
  if (out.kind === "ok") await mirrorDevice(deviceId);
  return out;
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
            ...out.reply,
            ...uploadPace(),
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
