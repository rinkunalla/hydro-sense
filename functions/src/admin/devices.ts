// Admin device management.
// Admins never read devices or device_health directly; adminListDevices returns
// only the fields an admin may see.
import { FieldValue, type DocumentSnapshot } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/https";
import { RESTORE_WINDOW_DAYS } from "../config";
import { requireAdmin } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { MAIL_SECRETS } from "../lib/providers";
import { confirmMatches, parseDeviceId, parseLabel, parseUid } from "../lib/userInput";
import { audit } from "./audit";
import { setOwner } from "./ownership";
import { mirrorDevice, readAllLive } from "../lib/liveStore";

const DAY_MS = 86_400_000;

const fail = (
  status: "not-found" | "failed-precondition" | "invalid-argument" | "already-exists",
  code: string,
  message: string,
) => new HttpsError(status, message, { code });

async function allowedEntry(deviceId: string) {
  const snap = await db.collection(C.allowedDevices).doc(deviceId).get();
  if (!snap.exists) throw fail("not-found", "DEVICE_NOT_FOUND", "This device ID is not listed.");
  return snap;
}

/** Puts a removed device back: allowlist entry (with its label) and no removal fields. */
async function unremove(deviceId: string, device: DocumentSnapshot, nowMs: number) {
  const label = (device.get("removedLabel") as string | null | undefined) ?? null;
  const batch = db.batch();
  batch.set(db.collection(C.allowedDevices).doc(deviceId), {
    addedAt: ts(nowMs),
    ...(label ? { label } : {}),
  });
  batch.update(device.ref, {
    removedAt: FieldValue.delete(),
    purgeAfter: FieldValue.delete(),
    removedBy: FieldValue.delete(),
    removedLabel: FieldValue.delete(),
  });
  await batch.commit();
  await mirrorDevice(deviceId);
  return label;
}

/** Adds an ID to the allowlist. Re-adding a removed ID restores it. */
export const addAllowedDevice = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const adminUid = await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const deviceId = parseDeviceId(d.deviceId);
  const label = parseLabel(d.label);
  const nowMs = Date.now();

  const device = await db.collection(C.devices).doc(deviceId).get();
  if (device.get("removedAt")) {
    const kept = await unremove(deviceId, device, nowMs);
    if (label) await db.collection(C.allowedDevices).doc(deviceId).update({ label });
    await audit({
      adminUid,
      action: "device_restored",
      targetId: deviceId,
      targetName: label ?? kept ?? deviceId,
      nowMs,
    });
    return { deviceId, restored: true };
  }

  const ref = db.collection(C.allowedDevices).doc(deviceId);
  const existing = await ref.get();
  if (existing.exists) {
    throw fail("already-exists", "DEVICE_EXISTS", "This device is already added.");
  }
  await ref.set({ addedAt: ts(nowMs), ...(label ? { label } : {}) });
  return { deviceId, restored: false };
});

export const updateDeviceLabel = onCall(async (request) => {
  await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const deviceId = parseDeviceId(d.deviceId);
  const label = parseLabel(d.label);
  const entry = await allowedEntry(deviceId);
  await entry.ref.update({ label: label ?? FieldValue.delete() });
  return { deviceId, label };
});

export const assignDevice = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const adminUid = await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const deviceId = parseDeviceId(d.deviceId);
  const uid = d.uid === null ? null : parseUid(d.uid);
  const entry = await allowedEntry(deviceId);

  if (uid !== null) {
    const user = await db.collection(C.users).doc(uid).get();
    if (!user.exists || user.get("role") !== "user") {
      throw fail("not-found", "USER_NOT_FOUND", "User not found.");
    }
    if (user.get("status") !== "active") {
      throw fail("failed-precondition", "USER_SUSPENDED", "This user is deleted.");
    }
  }

  const change = await setOwner(deviceId, uid);
  if (change.kind === "changed" && change.from !== null) {
    const label = (entry.get("label") as string | undefined) ?? deviceId;
    await audit({ adminUid, action: "device_reassigned", targetId: deviceId, targetName: label });
  }
  return {
    deviceId,
    uid,
    changed: change.kind === "changed",
    created: change.kind === "changed" && change.created,
  };
});

/** Takes the ID off the allowlist and keeps its data for the restore window. */
export const removeDevice = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const adminUid = await requireAdmin(request);
  const d = (request.data ?? {}) as Record<string, unknown>;
  const deviceId = parseDeviceId(d.deviceId);
  const entry = await allowedEntry(deviceId);
  const label = (entry.get("label") as string | undefined) ?? null;
  if (!confirmMatches(d.confirmLabel, label ?? deviceId)) {
    throw fail("invalid-argument", "CONFIRM_MISMATCH", "The typed label does not match.");
  }

  const nowMs = Date.now();
  const purgeAfterMs = nowMs + RESTORE_WINDOW_DAYS * DAY_MS;
  const deviceRef = db.collection(C.devices).doc(deviceId);
  const batch = db.batch();
  batch.delete(entry.ref);
  batch.delete(db.collection(C.deviceSecrets).doc(deviceId));
  if ((await deviceRef.get()).exists) {
    batch.update(deviceRef, {
      removedAt: ts(nowMs),
      purgeAfter: ts(purgeAfterMs),
      removedBy: adminUid,
      removedLabel: label,
    });
  }
  await batch.commit();
  await mirrorDevice(deviceId); // drops the token hash: the device can no longer upload
  await audit({
    adminUid,
    action: "device_removed",
    targetId: deviceId,
    targetName: label ?? deviceId,
    nowMs,
  });
  return { deviceId, purgeAfterMs };
});

export const restoreDevice = onCall({ secrets: MAIL_SECRETS }, async (request) => {
  const adminUid = await requireAdmin(request);
  const deviceId = parseDeviceId((request.data as { deviceId?: unknown } | null)?.deviceId);
  const device = await db.collection(C.devices).doc(deviceId).get();
  const purgeAfterMs = ms(device.get("purgeAfter"));
  const nowMs = Date.now();
  if (!device.get("removedAt")) {
    throw fail("failed-precondition", "NOT_SUSPENDED", "This device is not removed.");
  }
  if (purgeAfterMs === null || purgeAfterMs <= nowMs) {
    throw fail("failed-precondition", "RESTORE_EXPIRED", "The 30 days to restore have passed.");
  }
  const label = await unremove(deviceId, device, nowMs);
  await audit({
    adminUid,
    action: "device_restored",
    targetId: deviceId,
    targetName: label ?? deviceId,
    nowMs,
  });
  return { deviceId };
});

export interface AdminDeviceRow {
  id: string;
  label: string | null;
  ownerUid: string | null;
  ownerName: string | null;
  registered: boolean;
  online: boolean;
  lastSeenMs: number | null;
  removedAtMs: number | null;
  purgeAfterMs: number | null;
}

/**
 * Every allowlisted ID plus every removed device still inside its restore window.
 * Only the admin fields leave the server; removed rows add the dates needed to restore.
 */
export async function listDevicesForAdmin(): Promise<AdminDeviceRow[]> {
  const [allowed, removed] = await Promise.all([
    db.collection(C.allowedDevices).get(),
    db.collection(C.devices).where("removedAt", "!=", null).get(),
  ]);
  const ids = [...new Set([...allowed.docs.map((d) => d.id), ...removed.docs.map((d) => d.id)])];
  if (ids.length === 0) return [];
  // online and lastSeen come from the live channel; never flow or battery.
  const [devices, health, live] = await Promise.all([
    db.getAll(...ids.map((id) => db.collection(C.devices).doc(id))),
    db.getAll(...ids.map((id) => db.collection(C.deviceHealth).doc(id))),
    readAllLive(),
  ]);
  const owners = [
    ...new Set(devices.map((d) => d.get("ownerUid") as string | null).filter(Boolean)),
  ];
  const names = new Map<string, string>();
  if (owners.length > 0) {
    const users = await db.getAll(...owners.map((u) => db.collection(C.users).doc(u as string)));
    for (const u of users) names.set(u.id, (u.get("name") as string | undefined) ?? u.id);
  }
  const labels = new Map(allowed.docs.map((d) => [d.id, (d.get("label") as string) ?? null]));

  return ids.map((id, i) => {
    const dev = devices[i]!;
    const h = health[i]!;
    const ownerUid = (dev.get("ownerUid") as string | null | undefined) ?? null;
    return {
      id,
      label: labels.get(id) ?? (dev.get("removedLabel") as string | null | undefined) ?? null,
      ownerUid,
      ownerName: ownerUid ? (names.get(ownerUid) ?? null) : null,
      registered: Boolean(h.get("registeredAt")),
      online: live.get(id)?.online ?? false,
      lastSeenMs: live.get(id)?.lastSeen ?? null,
      removedAtMs: ms(dev.get("removedAt")),
      purgeAfterMs: ms(dev.get("purgeAfter")),
    };
  });
}

export const adminListDevices = onCall(async (request) => {
  await requireAdmin(request);
  return { rows: await listDevicesForAdmin() };
});
