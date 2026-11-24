// Full deletion of a device (Remove device, D66: no restore window) and its
// place in the organization's pipeline.
import { FieldValue } from "firebase-admin/firestore";
import { FAMILIES } from "../lib/alertLogic";
import { C, PIPELINE_DOC, db } from "../lib/db";
import { deleteLiveNodes } from "../lib/liveStore";
import { deleteDeviceProblems, deleteDeviceReadings } from "../lib/problems";
import { alertStateRef } from "../alerts/alertPass";

/** Removes one device ID from every branch of the pipeline (transaction). */
export async function removeFromPipeline(deviceId: string): Promise<void> {
  const ref = db.collection(C.pipelines).doc(PIPELINE_DOC);
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

/** Deletes every trace of a device: records, history, live nodes, pipeline place. */
export async function deleteDeviceData(deviceId: string): Promise<void> {
  // Allowlist and token first: from here on the device can neither upload nor register.
  const first = db.batch();
  first.delete(db.collection(C.allowedDevices).doc(deviceId));
  first.delete(db.collection(C.deviceSecrets).doc(deviceId));
  await first.commit();
  await deleteLiveNodes(deviceId);
  await db.recursiveDelete(db.collection(C.devices).doc(deviceId)); // includes flow_logs
  await db.recursiveDelete(db.collection(C.deviceHealth).doc(deviceId));
  const batch = db.batch();
  for (const f of FAMILIES) batch.delete(alertStateRef(deviceId, f));
  await batch.commit();
  await deleteDeviceProblems(deviceId);
  await deleteDeviceReadings(deviceId);
  await removeFromPipeline(deviceId);
}
