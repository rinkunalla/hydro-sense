// Weekly purge after the restore window, run by the weekly job
// before calibration. Each item is wrapped so one failure never stops the rest.
import { getAuth } from "firebase-admin/auth";
import { C, db, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { deleteDeviceData, setOwner } from "./ownership";
import { deleteUserProblems } from "../lib/problems";

const SOURCE = "purge";

export interface PurgeResult {
  users: string[];
  devices: string[];
}

/** Deletes one suspended user: devices unassigned (history deleted), then every record. */
export async function purgeUser(uid: string): Promise<void> {
  const owned = await db.collection(C.devices).where("ownerUid", "==", uid).get();
  for (const d of owned.docs) await setOwner(d.id, null);
  await deleteUserProblems(uid);

  const user = await db.collection(C.users).doc(uid).get();
  const phone = user.get("phone") as string | undefined;
  await db.recursiveDelete(db.collection(C.users).doc(uid)); // includes push_tokens
  const batch = db.batch();
  batch.delete(db.collection(C.pipelines).doc(uid));
  batch.delete(db.collection(C.passwordResets).doc(uid));
  if (phone) batch.delete(db.collection(C.phoneIndex).doc(phone));
  await batch.commit();
  await getAuth()
    .deleteUser(uid)
    .catch((e: { code?: string }) => {
      if (e.code !== "auth/user-not-found") throw e;
    });
}

export async function purgeExpired(nowMs = Date.now()): Promise<PurgeResult> {
  const now = ts(nowMs);
  const [users, devices] = await Promise.all([
    db.collection(C.users).where("status", "==", "suspended").where("purgeAfter", "<=", now).get(),
    db.collection(C.devices).where("purgeAfter", "<=", now).get(),
  ]);

  const done: PurgeResult = { users: [], devices: [] };
  for (const d of devices.docs) {
    try {
      await deleteDeviceData(d.id);
      done.devices.push(d.id);
    } catch (e) {
      await logError({
        source: SOURCE,
        code: "INTERNAL",
        message: String(e),
        deviceId: d.id,
        nowMs,
      });
    }
  }
  for (const u of users.docs) {
    try {
      await purgeUser(u.id);
      done.users.push(u.id);
    } catch (e) {
      await logError({ source: SOURCE, code: "INTERNAL", message: String(e), nowMs });
    }
  }
  if (done.users.length + done.devices.length > 0) {
    console.log(
      JSON.stringify({
        severity: "INFO",
        event: "purged",
        users: done.users.length,
        devices: done.devices.length,
      }),
    );
  }
  return done;
}
