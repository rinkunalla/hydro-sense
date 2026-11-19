// A phone registers for push through this callable, not a direct write.
// The app signs out on every fresh start but keeps the phone registered, so
// whoever signs in next on that phone takes its registration over: the same
// FID under any other account is removed first, and a phone never gets two
// people's alerts.
import { HttpsError, onCall } from "firebase-functions/https";
import { requireUser } from "../lib/auth";
import { C, db, ts } from "../lib/db";

const FID = /^[A-Za-z0-9_:-]{8,4096}$/;

export async function claimPushTokenFor(
  uid: string,
  fid: unknown,
  nowMs = Date.now(),
): Promise<{ removed: number }> {
  if (typeof fid !== "string" || !FID.test(fid)) {
    throw new HttpsError("invalid-argument", "Bad push registration.", { code: "PAYLOAD_INVALID" });
  }
  const same = await db.collectionGroup(C.pushTokens).where("fid", "==", fid).get();
  const batch = db.batch();
  let removed = 0;
  for (const d of same.docs) {
    if (d.ref.parent.parent?.id !== uid) {
      batch.delete(d.ref);
      removed++;
    }
  }
  batch.set(db.collection(C.users).doc(uid).collection(C.pushTokens).doc(fid), {
    platform: "android",
    fid,
    updatedAt: ts(nowMs),
  });
  await batch.commit();
  return { removed };
}

export const claimPushToken = onCall(async (request) => {
  const uid = await requireUser(request);
  return claimPushTokenFor(uid, (request.data as { fid?: unknown } | null)?.fid);
});
