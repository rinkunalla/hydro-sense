// Admin device management (D62, D63). Every device belongs to the
// organization; members read devices and the live channel directly, and only
// these callables change a device. Each change reaches the live channel's
// state (mirrorDevice) and so the device's next upload reply.
import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/https";
import { SENSORS, type SensorType } from "../config";
import { requireAdmin } from "../lib/auth";
import { C, db, ts } from "../lib/db";
import { newDeviceDoc, newHealthDoc } from "../lib/deviceDocs";
import { mirrorDevice } from "../lib/liveStore";
import { isSensorType, sensorOf, starterCutoffs } from "../lib/sensors";
import { confirmMatches, parseDeviceId, parseDeviceName } from "../lib/userInput";
import { deleteDeviceData } from "./ownership";

const fail = (
  status: "not-found" | "invalid-argument" | "already-exists",
  code: string,
  message: string,
) => new HttpsError(status, message, { code });

function parseSensor(v: unknown): SensorType {
  if (!isSensorType(v)) throw fail("invalid-argument", "SENSOR_INVALID", "Choose a sensor type.");
  return v;
}

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/** Manual pin: both null (clear), or both in range. */
function parsePin(
  lat: unknown,
  lng: unknown,
): { manualLat: number | null; manualLng: number | null } {
  if (lat === null && lng === null) return { manualLat: null, manualLng: null };
  if (isNum(lat) && isNum(lng) && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180) {
    return { manualLat: lat, manualLng: lng };
  }
  throw fail("invalid-argument", "PIN_INVALID", "Place the pin on the map.");
}

/** null = automatic limits; otherwise inside the sensor's reliable range. */
function parseUserCutoff(v: unknown, sensor: SensorType): number | null {
  if (v === null) return null;
  const { userCutoffMin, userCutoffMax } = SENSORS[sensor];
  if (isNum(v) && v >= userCutoffMin && v <= userCutoffMax) return v;
  throw fail(
    "invalid-argument",
    "CUTOFF_INVALID",
    `Use ${userCutoffMin} to ${userCutoffMax} L/min for this sensor.`,
  );
}

/**
 * {deviceId, name?, sensorType?}: lists the ID and creates its records at once,
 * so members see it as Not set up yet until its first registration.
 */
export const addAllowedDevice = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const deviceId = parseDeviceId(d.deviceId);
  const name =
    d.name === undefined || d.name === null || d.name === "" ? null : parseDeviceName(d.name);
  const sensorType = d.sensorType === undefined ? sensorOf(null) : parseSensor(d.sensorType);
  const nowMs = Date.now();

  await db.runTransaction(async (tx) => {
    const allowedRef = db.collection(C.allowedDevices).doc(deviceId);
    const deviceRef = db.collection(C.devices).doc(deviceId);
    const healthRef = db.collection(C.deviceHealth).doc(deviceId);
    const [allowed, device, health] = await Promise.all([
      tx.get(allowedRef),
      tx.get(deviceRef),
      tx.get(healthRef),
    ]);
    if (allowed.exists)
      throw fail("already-exists", "DEVICE_EXISTS", "This device is already added.");
    tx.set(allowedRef, { addedAt: ts(nowMs) });
    if (!device.exists)
      tx.create(deviceRef, newDeviceDoc(deviceId, ts(nowMs), { name, sensorType }));
    if (!health.exists) tx.create(healthRef, newHealthDoc(null, null));
  });
  await mirrorDevice(deviceId);
  return { deviceId };
});

/**
 * {deviceId, name?, manualLat?, manualLng?, userNormalCutoff?, sensorType?}.
 * A new sensor type starts over from that sensor's starter limits: automatic
 * values and the admin's own limit both belonged to the old sensor.
 */
export const updateDevice = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const deviceId = parseDeviceId(d.deviceId);
  const ref = db.collection(C.devices).doc(deviceId);
  const snap = await ref.get();
  if (!snap.exists) throw fail("not-found", "DEVICE_NOT_FOUND", "This device ID is not listed.");

  const current = sensorOf(snap.get("sensorType"));
  const sensor = d.sensorType === undefined ? current : parseSensor(d.sensorType);
  const update: Record<string, unknown> = {};
  if (d.name !== undefined) update.nickname = parseDeviceName(d.name);
  if (d.manualLat !== undefined || d.manualLng !== undefined) {
    Object.assign(update, parsePin(d.manualLat ?? null, d.manualLng ?? null));
  }
  if (sensor !== current) {
    Object.assign(update, {
      sensorType: sensor,
      ...starterCutoffs(sensor),
      userNormalCutoff: null,
      calibratedAt: null,
    });
  }
  if (d.userNormalCutoff !== undefined) {
    update.userNormalCutoff = parseUserCutoff(d.userNormalCutoff, sensor);
  }
  if (Object.keys(update).length === 0) return { deviceId };
  await ref.update({ ...update, updatedAt: FieldValue.serverTimestamp() });
  await mirrorDevice(deviceId); // the device gets the new limits and factor in its next reply
  return { deviceId };
});

/** {deviceId, confirmName}: deletes the device and its history at once (D66). */
export const removeDevice = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const deviceId = parseDeviceId(d.deviceId);
  const [allowed, device] = await Promise.all([
    db.collection(C.allowedDevices).doc(deviceId).get(),
    db.collection(C.devices).doc(deviceId).get(),
  ]);
  if (!allowed.exists && !device.exists) {
    throw fail("not-found", "DEVICE_NOT_FOUND", "This device ID is not listed.");
  }
  const name = (device.get("nickname") as string | undefined) ?? deviceId;
  if (!confirmMatches(d.confirmName, name)) {
    throw fail("invalid-argument", "CONFIRM_MISMATCH", "The typed name does not match.");
  }
  await deleteDeviceData(deviceId);
  return { deviceId };
});
