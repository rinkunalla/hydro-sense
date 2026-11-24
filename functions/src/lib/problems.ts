// Problem records for History: one Firestore doc per problem, with a start
// and an end. Only the functions create and close them; an admin may delete
// an ended one (D63). Every member reads them (D62).
import { PROBLEM_TTL_DAYS } from "../config";
import { C, db, ts } from "./db";
import { PROBLEM_MIN_MS, type ProblemOp, type ProblemType } from "./live";

const DAY_MS = 86_400_000;

export const problemsCol = () => db.collection(C.problems);

const record = (deviceId: string, type: ProblemType, startedAt: number) => ({
  deviceId,
  type,
  startedAt: ts(startedAt),
  endedAt: null,
  expireAt: ts(startedAt + PROBLEM_TTL_DAYS * DAY_MS),
});

/** Applies open/close operations for one device and returns the open IDs after them. */
export async function applyProblemOps(
  deviceId: string,
  open: Partial<Record<ProblemType, string>>,
  ops: ProblemOp[],
): Promise<Partial<Record<ProblemType, string>>> {
  const next = { ...open };
  if (ops.length === 0) return next;
  const batch = db.batch();
  for (const op of ops) {
    if (op.op === "close") {
      delete next[op.type];
      const ref = problemsCol().doc(op.id);
      if (op.dropIfShort) {
        // A blip shorter than the alert confirmation is not history.
        const snap = await ref.get();
        const started = snap.get("startedAt")?.toMillis?.() as number | undefined;
        if (snap.exists && started !== undefined && op.endedAt - started < PROBLEM_MIN_MS) {
          batch.delete(ref);
          continue;
        }
      }
      // update, not set: a record an admin deleted is never brought back.
      batch.update(ref, { endedAt: ts(op.endedAt) });
    } else {
      const ref = problemsCol().doc();
      batch.create(ref, record(deviceId, op.type, op.startedAt));
      next[op.type] = ref.id;
    }
  }
  try {
    await batch.commit();
  } catch (e) {
    // NOT_FOUND: an admin deleted an ended record (only ended ones can be
    // deleted, so this is a race at worst). Retry without the updates.
    if ((e as { code?: number }).code !== 5) throw e;
    const retry = db.batch();
    for (const op of ops) {
      if (op.op !== "open") continue;
      const id = next[op.type];
      if (id) retry.set(problemsCol().doc(id), record(deviceId, op.type, op.startedAt));
    }
    await retry.commit();
  }
  return next;
}

/** Deletes every problem record of a device (Remove device). */
export async function deleteDeviceProblems(deviceId: string): Promise<void> {
  await deleteQuery(problemsCol().where("deviceId", "==", deviceId));
}

/** Deletes a device's History graph days (Remove device). */
export async function deleteDeviceReadings(deviceId: string): Promise<void> {
  await deleteQuery(db.collection(C.readings).where("deviceId", "==", deviceId));
}

async function deleteQuery(q: FirebaseFirestore.Query): Promise<void> {
  for (;;) {
    const snap = await q.limit(400).get();
    if (snap.empty) return;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
}
