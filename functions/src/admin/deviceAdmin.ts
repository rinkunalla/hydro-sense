import { HttpsError, onCall } from "firebase-functions/https";
import { FAMILIES } from "../lib/alertLogic";
import { requireAdmin } from "../lib/auth";
import { C, db, ts } from "../lib/db";
import { normalizeDeviceId } from "../lib/payload";
import { alertStateRef } from "../alerts/alertPass";

function deviceIdFrom(data: unknown): string {
  const id = normalizeDeviceId((data as { deviceId?: unknown } | null)?.deviceId);
  if (!id) {
    throw new HttpsError("invalid-argument", "Device ID must be 12 hex characters.", {
      code: "DEVICE_ID_INVALID",
    });
  }
  return id;
}

/** Deletes a device's data and allowlist entry and writes the tombstone (CLAUDE.md section 3). */
export async function removeDeviceData(deviceId: string, nowMs = Date.now()) {
  await db.recursiveDelete(db.collection(C.devices).doc(deviceId));
  await db.recursiveDelete(db.collection(C.deviceHealth).doc(deviceId));
  const batch = db.batch();
  batch.delete(db.collection(C.deviceSecrets).doc(deviceId));
  batch.delete(db.collection(C.allowedDevices).doc(deviceId));
  for (const f of FAMILIES) batch.delete(alertStateRef(deviceId, f));
  batch.set(db.collection(C.removedDevices).doc(deviceId), { removedAt: ts(nowMs) });
  await batch.commit();
}

export const removeDevice = onCall(async (request) => {
  requireAdmin(request);
  const deviceId = deviceIdFrom(request.data);
  await removeDeviceData(deviceId);
  return { deviceId };
});

/** "Allow again": deletes the tombstone and re-adds the allowlist entry. */
export const allowDevice = onCall(async (request) => {
  requireAdmin(request);
  const deviceId = deviceIdFrom(request.data);
  const batch = db.batch();
  batch.delete(db.collection(C.removedDevices).doc(deviceId));
  batch.set(db.collection(C.allowedDevices).doc(deviceId), { addedAt: ts(Date.now()) });
  await batch.commit();
  return { deviceId };
});
