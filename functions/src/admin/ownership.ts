// Device ownership changes and full deletion. Used by
// assignDevice, the weekly purge and the migration tests.
import { FieldValue } from "firebase-admin/firestore";
import { FAMILIES } from "../lib/alertLogic";
import { C, db, ts } from "../lib/db";
import { newDeviceDoc, newHealthDoc, ownerResetFields } from "../lib/deviceDocs";
import { clearOpenProblems, clearSeries, deleteLiveNodes, mirrorDevice } from "../lib/liveStore";
import { deleteDeviceProblems, deleteDeviceReadings } from "../lib/problems";
import { alertStateRef } from "../alerts/alertPass";

export type OwnerChange =
  | { kind: "unchanged" }
  | { kind: "changed"; from: string | null; to: string | null; created: boolean };

/** Removes one device ID from every branch of a user's pipeline (transaction). */
export async function removeFromPipeline(uid: string, deviceId: string): Promise<void> {
  const ref = db.collection(C.pipelines).doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const branches = snap.get("branches") as { deviceIds?: unknown }[] | undefined;
    if (!snap.exists || !Array.isArray(branches)) return;
    let changed = false;
    const next = branches.map((b) => {
      const ids = Array.isArray(b.deviceIds) ? (b.deviceIds as unknown[]) : [];
      const kept = ids.filter((id) => id !== deviceId);
      if (kept.length !== ids.length) changed = true;
      return { ...b, deviceIds: kept };
    });
    if (changed) tx.update(ref, { branches: next, updatedAt: FieldValue.serverTimestamp() });
  });
}

/** Flow history, problems and alert state: everything the next owner must never inherit. */
async function wipeHistory(deviceId: string): Promise<void> {
  await db.recursiveDelete(db.collection(C.devices).doc(deviceId).collection(C.flowLogs));
  await deleteDeviceProblems(deviceId);
  await deleteDeviceReadings(deviceId);
  await clearSeries(deviceId);
  await clearOpenProblems(deviceId);
  const batch = db.batch();
  for (const f of FAMILIES) batch.delete(alertStateRef(deviceId, f));
  await batch.commit();
}

/**
 * Keeps users/{uid}.deviceCount right after an ownership change has committed.
 * Called with every user whose device set may have changed (null entries skipped).
 * Callers: setOwner (assign, reassign, unassign, first assignment) and deleteDeviceData (purge).
 */
export async function updateDeviceCounts(uids: (string | null)[]): Promise<void> {
  // Recount instead of +1/-1, so a missed path can never leave a wrong count for good.
  // A removed device still counts: it stays assigned until restored or purged.
  const NOT_FOUND = 5; // user doc already gone during a purge
  for (const uid of new Set(uids)) {
    if (!uid) continue;
    const owned = await db.collection(C.devices).where("ownerUid", "==", uid).count().get();
    await db
      .collection(C.users)
      .doc(uid)
      .update({ deviceCount: owned.data().count })
      .catch((e: { code?: number }) => {
        if (e.code !== NOT_FOUND) throw e;
      });
  }
}

/**
 * Sets a device's owner. When the owner changes, the device is first detached
 * (ownerUid null: nobody can read it), its history is wiped, and only then is it
 * attached to the new owner, so the new owner can never read the old history.
 * An allowlisted ID that never registered gets its records here.
 */
export async function setOwner(
  deviceId: string,
  to: string | null,
  nowMs = Date.now(),
): Promise<OwnerChange> {
  const deviceRef = db.collection(C.devices).doc(deviceId);
  const healthRef = db.collection(C.deviceHealth).doc(deviceId);

  // Phase 1: detach (or create, for a device that has never registered).
  const first = await db.runTransaction(async (tx) => {
    const device = await tx.get(deviceRef);
    if (!device.exists) {
      if (to === null) return { kind: "unchanged" } as const;
      tx.create(deviceRef, newDeviceDoc(deviceId, to, ts(nowMs)));
      tx.create(healthRef, newHealthDoc(to, null, null));
      return { kind: "created" } as const;
    }
    const from = (device.get("ownerUid") as string | null | undefined) ?? null;
    if (from === to) return { kind: "unchanged" } as const;
    tx.update(deviceRef, { ownerUid: null, ...ownerResetFields(deviceId) });
    tx.set(healthRef, { ownerUid: null }, { merge: true });
    return { kind: "detached", from } as const;
  });

  if (first.kind === "unchanged") return { kind: "unchanged" };
  if (first.kind === "created") {
    await mirrorDevice(deviceId);
    await updateDeviceCounts([to]);
    return { kind: "changed", from: null, to, created: true };
  }

  // Phase 2: nobody can read the device now (the live node follows the detach),
  // then delete what the old owner caused.
  await mirrorDevice(deviceId);
  await wipeHistory(deviceId);
  if (first.from) await removeFromPipeline(first.from, deviceId);

  // Phase 3: attach.
  if (to !== null) {
    const batch = db.batch();
    batch.update(deviceRef, { ownerUid: to });
    batch.set(healthRef, { ownerUid: to }, { merge: true });
    await batch.commit();
    await mirrorDevice(deviceId);
  }
  await updateDeviceCounts([first.from, to]);
  return { kind: "changed", from: first.from, to, created: false };
}

/** Deletes every trace of a device (purge after the restore window). */
export async function deleteDeviceData(deviceId: string): Promise<void> {
  const device = await db.collection(C.devices).doc(deviceId).get();
  const owner = (device.get("ownerUid") as string | null | undefined) ?? null;
  await db.recursiveDelete(db.collection(C.devices).doc(deviceId));
  await db.recursiveDelete(db.collection(C.deviceHealth).doc(deviceId));
  const batch = db.batch();
  batch.delete(db.collection(C.deviceSecrets).doc(deviceId));
  batch.delete(db.collection(C.allowedDevices).doc(deviceId));
  for (const f of FAMILIES) batch.delete(alertStateRef(deviceId, f));
  await batch.commit();
  await deleteDeviceProblems(deviceId);
  await deleteDeviceReadings(deviceId);
  await deleteLiveNodes(deviceId);
  if (owner) {
    await removeFromPipeline(owner, deviceId);
    await updateDeviceCounts([owner]);
  }
}
