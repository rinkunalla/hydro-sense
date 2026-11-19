// Mirrors a device's owner, removal and cutoffs to the live channel when
// devices/{id} changes. Server paths call mirrorDevice themselves; this catches
// the owner's own writes (userNormalCutoff), which reach the device in its
// next upload reply.
import { onDocumentWritten } from "firebase-functions/firestore";
import { mirrorDevice } from "../lib/liveStore";

const WATCHED = ["ownerUid", "removedAt", "lowFlowCutoff", "normalFlowCutoff", "userNormalCutoff"];

export const mirrorDeviceOnWrite = onDocumentWritten("devices/{deviceId}", async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  const changed =
    !before ||
    !after ||
    WATCHED.some((f) => JSON.stringify(before[f] ?? null) !== JSON.stringify(after[f] ?? null));
  if (changed) await mirrorDevice(event.params.deviceId);
});
