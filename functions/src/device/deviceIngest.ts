import { onRequest } from "firebase-functions/https";
import { DEVICE_ID_PATTERN, FLOW_LOG_SAMPLE_S, FLOW_LOG_TTL_DAYS } from "../config";
import { effectiveCutoffs } from "../lib/cutoffs";
import { appendVoltage, batteryPercent, chargingTrend, smoothedVoltage } from "../lib/battery";
import { C, db, ms, ts } from "../lib/db";
import { nextAbnormalSince, sampleDue, shouldWriteDevices, uploadPace } from "../lib/decisions";
import { bearerToken, header, sendError, sendOk } from "../lib/http";
import { logError } from "../lib/logError";
import { parseIngestPayload, type FlowStatus, type IngestPayload } from "../lib/payload";
import { safeEqual, sha256Hex } from "../lib/tokens";

const DAY_MS = 86_400_000;

type Outcome =
  | { kind: "ok"; lowFlowCutoff: number; normalFlowCutoff: number; wrote: string[] }
  | { kind: "unknown_device" };

/** Applies one upload. Exported for the emulator tests. */
export async function ingest(deviceId: string, p: IngestPayload, nowMs: number) {
  const deviceRef = db.collection(C.devices).doc(deviceId);
  const healthRef = db.collection(C.deviceHealth).doc(deviceId);

  return db.runTransaction<Outcome>(async (tx) => {
    const [device, health] = await Promise.all([tx.get(deviceRef), tx.get(healthRef)]);
    if (!device.exists || !health.exists) return { kind: "unknown_device" };

    const now = ts(nowMs);
    const wrote: string[] = ["device_health"];
    const prevStatus = (device.get("flowStatus") as FlowStatus | null) ?? null;
    const statusChanged = prevStatus !== p.flowStatus;
    const locationChanged =
      p.gpsValid && (device.get("gpsLat") !== p.lat || device.get("gpsLng") !== p.lng);

    if (
      shouldWriteDevices({
        statusChanged,
        locationChanged,
        prevRate: (device.get("flowRate") as number | null) ?? null,
        nextRate: p.flowRate,
        updatedAtMs: ms(device.get("updatedAt")),
        nowMs,
      })
    ) {
      const abnormalSinceMs = nextAbnormalSince(
        prevStatus,
        ms(device.get("abnormalSince")),
        p.flowStatus,
        nowMs,
      );
      tx.update(deviceRef, {
        flowStatus: p.flowStatus,
        flowRate: p.flowRate,
        ...(p.gpsValid ? { gpsLat: p.lat, gpsLng: p.lng } : {}),
        ...(statusChanged ? { statusChangedAt: now } : {}),
        abnormalSince: abnormalSinceMs === null ? null : ts(abnormalSinceMs),
        updatedAt: now,
      });
      wrote.push("devices");
    }

    const healthUpdate: Record<string, unknown> = {
      online: true,
      lastSeen: now,
      batteryFault: p.batteryFault,
      lowVoltageSleep: p.lowVoltageSleep,
      heartbeatS: p.heartbeatS,
      ...(p.firmware ? { firmware: p.firmware } : {}),
      ...(p.rssi !== null ? { rssi: p.rssi } : {}),
      ...(p.resetReason ? { resetReason: p.resetReason, resetAt: now } : {}),
    };

    if (p.batteryVoltage !== null) {
      const recent = appendVoltage(
        (health.get("recentVoltages") as number[] | undefined) ?? [],
        p.batteryVoltage,
      );
      Object.assign(healthUpdate, {
        batteryVoltage: p.batteryVoltage,
        batteryPercent: batteryPercent(smoothedVoltage(recent)),
        chargingStatus: chargingTrend(recent),
        recentVoltages: recent,
      });
    } else {
      Object.assign(healthUpdate, { batteryVoltage: null, batteryPercent: null });
    }

    if (statusChanged || sampleDue(ms(health.get("lastFlowLogAt")), nowMs, FLOW_LOG_SAMPLE_S)) {
      tx.create(deviceRef.collection(C.flowLogs).doc(), {
        ts: now,
        flowStatus: p.flowStatus,
        flowRate: p.flowRate,
        trigger: statusChanged ? "status_change" : p.trigger,
        expireAt: ts(nowMs + FLOW_LOG_TTL_DAYS * DAY_MS),
      });
      healthUpdate.lastFlowLogAt = now;
      wrote.push("flow_logs");
    }

    tx.update(healthRef, healthUpdate);

    return {
      kind: "ok",
      wrote,
      ...effectiveCutoffs((f) => device.get(f)),
    };
  });
}

export const deviceIngest = onRequest({ invoker: "public" }, async (req, res) => {
  const source = "deviceIngest";
  if (req.method !== "POST") return sendError(res, "PAYLOAD_INVALID", "Use POST.");

  const deviceId = header(req, "X-Device-Id");
  const token = bearerToken(req);
  if (deviceId === null || !DEVICE_ID_PATTERN.test(deviceId) || token === null) {
    return sendError(res, "DEVICE_AUTH_FAILED", "Missing or malformed device credentials.");
  }

  try {
    const secret = await db.collection(C.deviceSecrets).doc(deviceId).get();
    const hash = secret.get("tokenHash") as string | undefined;
    if (!hash || !safeEqual(sha256Hex(token), hash)) {
      // Log against the device only if it exists, so random IDs cannot flood error_logs.
      await logError({
        source,
        code: "DEVICE_AUTH_FAILED",
        message: "Token rejected",
        ...(secret.exists ? { deviceId } : {}),
      });
      return sendError(res, "DEVICE_AUTH_FAILED", "Device token rejected.");
    }

    const parsed = parseIngestPayload(req.body);
    if (!parsed.ok) {
      await logError({ source, code: "PAYLOAD_INVALID", message: parsed.error, deviceId });
      return sendError(res, "PAYLOAD_INVALID", parsed.error);
    }

    const out = await ingest(deviceId, parsed.value, Date.now());
    if (out.kind === "unknown_device") {
      return sendError(res, "DEVICE_AUTH_FAILED", "Device is not registered.");
    }
    if (parsed.value.resetReason) {
      await logError({
        source,
        code: "DEVICE_RESET",
        message: `Abnormal reset: ${parsed.value.resetReason}`,
        deviceId,
      });
    }
    return sendOk(res, {
      lowFlowCutoff: out.lowFlowCutoff,
      normalFlowCutoff: out.normalFlowCutoff,
      ...uploadPace(),
    });
  } catch (e) {
    await logError({ source, code: "INTERNAL", message: String(e), deviceId });
    return sendError(res, "INTERNAL", "Internal error.");
  }
});
