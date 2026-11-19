import { onRequest } from "firebase-functions/https";
import { runAlertPass } from "../alerts/alertPass";
import {
  ABNORMAL_CONFIRM_S,
  DEVICE_ID_PATTERN,
  FLOW_LOG_TTL_DAYS,
  LOW_BATTERY_PERCENT,
  READINGS_TTL_DAYS,
} from "../config";
import { manilaDateKey, manilaMinute, manilaSlot } from "../lib/time";
import { C, db, rtdb, ts } from "../lib/db";
import { uploadPace } from "../lib/decisions";
import { bearerToken, header, sendError, sendOk } from "../lib/http";
import { applyUpload, minutePeak, type Live } from "../lib/live";
import { mirrorDevice, readLive, readState } from "../lib/liveStore";
import { logError } from "../lib/logError";
import { ALERT_SECRETS } from "../lib/providers";
import { parseIngestPayload, type IngestPayload } from "../lib/payload";
import { applyProblemOps } from "../lib/problems";
import { safeEqual, sha256Hex } from "../lib/tokens";

const DAY_MS = 86_400_000;

type Outcome =
  | {
      kind: "ok";
      lowFlowCutoff: number;
      normalFlowCutoff: number;
      wrote: string[];
      live: Live;
    }
  | { kind: "unknown_device" };

/** The device's server-only state; mirrored from Firestore the first time it is missing. */
export async function loadState(deviceId: string) {
  let state = await readState(deviceId);
  if (!state.known && (await mirrorDevice(deviceId))) state = await readState(deviceId);
  return state;
}

/**
 * Applies one upload. A heartbeat writes only the Realtime Database;
 * Firestore gets a problem record on a change, a flow sample every 15 min and
 * a GPS move. Uploads of one device arrive one at a time (the firmware waits
 * for each reply), and the monitor flips offline in a transaction on /live.
 * Exported for the emulator tests.
 */
export async function ingest(
  deviceId: string,
  p: IngestPayload,
  nowMs: number,
  loaded?: Awaited<ReturnType<typeof loadState>>,
): Promise<Outcome> {
  const state = loaded ?? (await loadState(deviceId));
  if (!state.known) return { kind: "unknown_device" };
  const prev = await readLive(deviceId);
  const r = applyUpload(prev, state, p, nowMs);
  const wrote: string[] = ["live"];

  const open = await applyProblemOps(deviceId, state.ownerUid, state.open, r.problems);
  if (r.problems.length > 0) wrote.push("problems");

  const deviceRef = db.collection(C.devices).doc(deviceId);
  if (r.sample) {
    await deviceRef.collection(C.flowLogs).add({
      ts: ts(nowMs),
      flowStatus: p.flowStatus,
      flowRate: p.flowRate,
      trigger: p.trigger,
      expireAt: ts(nowMs + FLOW_LOG_TTL_DAYS * DAY_MS),
    });
    wrote.push("flow_logs");
    // The History graph: the same sample in the owner's day record.
    if (state.ownerUid) {
      const day = manilaDateKey(nowMs);
      await db
        .collection(C.readings)
        .doc(`${deviceId}_${day}`)
        .set(
          {
            ownerUid: state.ownerUid,
            deviceId,
            day,
            rates: { [String(manilaSlot(nowMs))]: p.flowRate },
            expireAt: ts(nowMs + READINGS_TTL_DAYS * DAY_MS),
          },
          { merge: true },
        );
      wrote.push("readings");
    }
  }
  if (r.gpsMoved) {
    await deviceRef.update({ gpsLat: p.lat, gpsLng: p.lng });
    wrote.push("devices");
  }
  const healthPatch: Record<string, unknown> = {};
  if (p.firmware) healthPatch.firmware = p.firmware;
  if (p.resetReason) Object.assign(healthPatch, { resetReason: p.resetReason, resetAt: ts(nowMs) });

  // Today's live series: the highest flow of this minute of the Manila
  // day, so the card's graph fills minute by minute and a short rise is kept.
  // A new day keeps yesterday (for the hours around midnight) and drops
  // anything older.
  const day = manilaDateKey(nowMs);
  const minute = `${day}/${manilaMinute(nowMs)}`;
  const peak = minutePeak(state.seriesMinute, state.seriesPeak, minute, p.flowRate);
  const series: Record<string, unknown> = {
    [`series/${deviceId}/${minute}`]: peak,
    [`state/${deviceId}/seriesMinute`]: minute,
    [`state/${deviceId}/seriesPeak`]: peak,
  };
  if (state.seriesDay !== day) {
    const kept = state.seriesDay;
    const old = ((await rtdb.ref(`series/${deviceId}`).get()).val() ?? {}) as Record<
      string,
      unknown
    >;
    for (const d of Object.keys(old)) {
      if (d !== day && d !== kept) series[`series/${deviceId}/${d}`] = null;
    }
    series[`state/${deviceId}/seriesDay`] = day;
  }

  await rtdb.ref().update({
    ...series,
    [`live/${deviceId}`]: r.live,
    [`state/${deviceId}/recentVoltages`]: r.state.recentVoltages,
    [`state/${deviceId}/lastSampleAt`]: r.state.lastSampleAt,
    [`state/${deviceId}/gpsLat`]: r.state.gpsLat,
    [`state/${deviceId}/gpsLng`]: r.state.gpsLng,
    [`state/${deviceId}/rssi`]: p.rssi,
    [`state/${deviceId}/open`]: open,
  });
  // Firmware version and abnormal resets change rarely; only then touch Firestore.
  if (p.resetReason || (p.firmware && p.firmware !== state.firmware)) {
    await db.collection(C.deviceHealth).doc(deviceId).set(healthPatch, { merge: true });
    await rtdb.ref(`state/${deviceId}/firmware`).set(p.firmware ?? state.firmware);
    wrote.push("device_health");
  }

  return {
    kind: "ok",
    wrote,
    live: r.live,
    lowFlowCutoff: state.lowFlowCutoff,
    normalFlowCutoff: state.normalFlowCutoff,
  };
}

/**
 * True when this upload may make an alert due: a flow problem confirmed
 * for ABNORMAL_CONFIRM_S, or a low battery. Then the alert check runs at once
 * for this device, instead of at the next once-a-minute monitor pass.
 */
export function alertMayBeDue(l: Live, nowMs: number): boolean {
  if (!l.ownerUid || l.removed) return false;
  const flow =
    (l.flowStatus === "No Flow" || l.flowStatus === "Low Flow") &&
    l.abnormalSince !== null &&
    nowMs - l.abnormalSince >= ABNORMAL_CONFIRM_S * 1000;
  const battery =
    !l.batteryFault && l.batteryPercent !== null && l.batteryPercent < LOW_BATTERY_PERCENT;
  return flow || battery;
}

export const deviceIngest = onRequest(
  { invoker: "public", secrets: ALERT_SECRETS },
  async (req, res) => {
    const source = "deviceIngest";
    if (req.method !== "POST") return sendError(res, "PAYLOAD_INVALID", "Use POST.");

    const deviceId = header(req, "X-Device-Id");
    const token = bearerToken(req);
    if (deviceId === null || !DEVICE_ID_PATTERN.test(deviceId) || token === null) {
      return sendError(res, "DEVICE_AUTH_FAILED", "Missing or malformed device credentials.");
    }

    try {
      const state = await loadState(deviceId);
      const hash = state.tokenHash;
      if (!hash || !safeEqual(sha256Hex(token), hash)) {
        // Log against the device only if it exists, so random IDs cannot flood error_logs.
        await logError({
          source,
          code: "DEVICE_AUTH_FAILED",
          message: "Token rejected",
          ...(state.known ? { deviceId } : {}),
        });
        return sendError(res, "DEVICE_AUTH_FAILED", "Device token rejected.");
      }

      const parsed = parseIngestPayload(req.body);
      if (!parsed.ok) {
        await logError({ source, code: "PAYLOAD_INVALID", message: parsed.error, deviceId });
        return sendError(res, "PAYLOAD_INVALID", parsed.error);
      }

      const out = await ingest(deviceId, parsed.value, Date.now(), state);
      if (out.kind === "unknown_device") {
        return sendError(res, "DEVICE_AUTH_FAILED", "Device is not registered.");
      }
      // Alerts at the upload itself: the locks, reminders and caps in the
      // alert pass still decide; a failure never fails the upload.
      const nowMs = Date.now();
      if (alertMayBeDue(out.live, nowMs)) {
        try {
          await runAlertPass(nowMs, new Map([[deviceId, out.live]]));
        } catch (e) {
          await logError({ source, code: "INTERNAL", message: `alerts: ${String(e)}`, deviceId });
        }
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
  },
);
