import { HttpsError, onCall } from "firebase-functions/https";
import { requireAdmin } from "../lib/auth";
import { C, db, ts } from "../lib/db";
import { normalizeDeviceId } from "../lib/payload";

/** Admin adds a device ID to the allowlist before it is powered on (CLAUDE.md D12). */
export const addAllowedDevice = onCall(async (request) => {
  requireAdmin(request);
  const deviceId = normalizeDeviceId((request.data as { deviceId?: unknown } | null)?.deviceId);
  if (deviceId === null) {
    throw new HttpsError("invalid-argument", "Device ID must be 12 hex characters.", {
      code: "DEVICE_ID_INVALID",
    });
  }

  const removed = await db.collection(C.removedDevices).doc(deviceId).get();
  if (removed.exists) {
    throw new HttpsError("failed-precondition", "This device was removed. Use Allow again.", {
      code: "DEVICE_REMOVED",
    });
  }

  await db
    .collection(C.allowedDevices)
    .doc(deviceId)
    .set({ addedAt: ts(Date.now()) });
  return { deviceId };
});
