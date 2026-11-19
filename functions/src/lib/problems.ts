// Problem records for History: one Firestore doc per problem, with a start
// and an end. Only the functions create them; the owner may note or delete them.
import { PROBLEM_TTL_DAYS } from "../config";
import { C, db, ts } from "./db";
import { PROBLEM_MIN_MS, type ProblemOp, type ProblemType } from "./live";

const DAY_MS = 86_400_000;

export const problemsCol = () => db.collection(C.problems);

/**
 * Applies open/close operations for one device and returns the open IDs after
 * them. Nothing is written for an unassigned device: nobody could read it.
 */
export async function applyProblemOps(
  deviceId: string,
  ownerUid: string | null,
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
      // update, not set: a record the owner deleted is never brought back.
      batch.update(ref, { endedAt: ts(op.endedAt) });
    } else if (ownerUid) {
      const ref = problemsCol().doc();
      batch.create(ref, {
        ownerUid,
        deviceId,
        type: op.type,
        startedAt: ts(op.startedAt),
        endedAt: null,
        note: null,
        expireAt: ts(op.startedAt + PROBLEM_TTL_DAYS * DAY_MS),
      });
      next[op.type] = ref.id;
    }
  }
  try {
    await batch.commit();
  } catch (e) {
    // NOT_FOUND: the owner deleted an ended record (only ended ones can be
    // deleted, so this is a race at worst). Retry without the updates.
    if ((e as { code?: number }).code !== 5) throw e;
    await applyOpens(deviceId, ownerUid, ops, next);
  }
  return next;
}

async function applyOpens(
  deviceId: string,
  ownerUid: string | null,
  ops: ProblemOp[],
  next: Partial<Record<ProblemType, string>>,
) {
  if (!ownerUid) return;
  const batch = db.batch();
  for (const op of ops) {
    if (op.op !== "open") continue;
    const id = next[op.type];
    if (!id) continue;
    batch.set(problemsCol().doc(id), {
      ownerUid,
      deviceId,
      type: op.type,
      startedAt: ts(op.startedAt),
      endedAt: null,
      note: null,
      expireAt: ts(op.startedAt + PROBLEM_TTL_DAYS * DAY_MS),
    });
  }
  await batch.commit();
}

/** Deletes every problem record of a device (reassign, unassign, purge). */
export async function deleteDeviceProblems(deviceId: string): Promise<void> {
  await deleteQuery(problemsCol().where("deviceId", "==", deviceId));
}

/** Deletes every problem record of a user (purge after the restore window). */
export async function deleteUserProblems(uid: string): Promise<void> {
  await deleteQuery(problemsCol().where("ownerUid", "==", uid));
  await deleteQuery(db.collection(C.readings).where("ownerUid", "==", uid));
}

/** Deletes a device's History graph days (reassign, unassign, purge). */
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
