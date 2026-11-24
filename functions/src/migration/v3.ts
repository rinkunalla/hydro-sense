// One-off v2 -> v3 data migration (KICKOFF.md stage V1). Not deployed: run by
// tools/migrate-v3.ts (dry run by default) and by the emulator tests. Safe to
// run twice: every step checks the current shape first.
//
// v2 had users who each owned devices; v3 is one organization (D62 to D66):
// - the building owner's user account (ownerUid option) becomes an admin;
// - every other user becomes a staff member who signs in with a username
//   (taken from the email's local part); their real email stays for alerts;
// - devices lose their owner and removal fields, gain a sensor type, and take
//   the admin label as their name while they still had the default name;
// - the owner's pipeline becomes the organization's one pipeline;
// - removed devices, the audit log and the reset-code records are deleted.
import { getAuth, type UserRecord } from "firebase-admin/auth";
import { FieldValue } from "firebase-admin/firestore";
import { deleteDeviceData } from "../admin/ownership";
import { C, PIPELINE_DOC, db, rtdb, ts } from "../lib/db";
import { mirrorDevice } from "../lib/liveStore";
import { setMember } from "../lib/members";
import { sensorOf } from "../lib/sensors";
import { defaultNickname, parseUsername, staffLoginEmail } from "../lib/userInput";

export interface MigrationStep {
  target: string;
  change: string;
}

export interface MigrationReport {
  applied: boolean;
  steps: MigrationStep[];
  problems: string[];
}

async function allAuthUsers(): Promise<UserRecord[]> {
  const out: UserRecord[] = [];
  let token: string | undefined;
  do {
    const page = await getAuth().listUsers(1000, token);
    out.push(...page.users);
    token = page.pageToken;
  } while (token);
  return out;
}

const del = () => FieldValue.delete();

/** The fields of `d` among `names` that exist, as deletes. */
function deletes(d: Record<string, unknown>, names: string[]): Record<string, unknown> {
  return Object.fromEntries(names.filter((n) => n in d).map((n) => [n, del()]));
}

const keysOf = (u: Record<string, unknown>) => Object.keys(u).sort().join(", ");

/** A free username from an email's local part ("juan.dela.cruz" -> "juan.dela.cruz", then "juan.dela.cruz2"). */
async function freeUsername(seed: string, taken: Set<string>): Promise<string | null> {
  for (let n = 1; n <= 50; n++) {
    let candidate: string;
    try {
      candidate = parseUsername(n === 1 ? seed : `${seed}${n}`);
    } catch {
      return null;
    }
    if (taken.has(candidate)) continue;
    try {
      await getAuth().getUserByEmail(staffLoginEmail(candidate));
    } catch {
      taken.add(candidate);
      return candidate;
    }
  }
  return null;
}

/** Plans (and with apply: true performs) the migration. */
export async function migrateV3(opts: {
  apply: boolean;
  /** The v2 user account of the building owner, who becomes the admin. */
  ownerUid: string | null;
  nowMs?: number;
}): Promise<MigrationReport> {
  const { apply, ownerUid } = opts;
  const now = ts(opts.nowMs ?? Date.now());
  const report: MigrationReport = { applied: apply, steps: [], problems: [] };
  const step = (target: string, change: string) => report.steps.push({ target, change });
  const auth = getAuth();
  const takenUsernames = new Set<string>();
  const memberIds = new Set(
    Object.keys(((await rtdb.ref("members").get()).val() ?? {}) as Record<string, unknown>),
  );
  const addMember = async (uid: string) => {
    if (memberIds.has(uid)) return;
    step(`members/${uid}`, "set");
    if (apply) await setMember(uid, true);
  };

  // 1. Accounts.
  for (const u of await allAuthUsers()) {
    const role = u.customClaims?.role;
    if (role === "admin") {
      const ref = db.collection(C.admins).doc(u.uid);
      const a = await ref.get();
      if (a.get("status") === "active") await addMember(u.uid);
      continue;
    }
    if (role !== "user") continue;
    const ref = db.collection(C.users).doc(u.uid);
    const d = (await ref.get()).data() ?? {};
    const old = [
      "deviceCount",
      "alertPrefs",
      "passwordSet",
      "suspendedAt",
      "purgeAfter",
      "deletionRequestedAt",
    ];

    if (u.uid === ownerUid) {
      // The building owner becomes the admin (D63): same account and password.
      step(`admins/${u.uid}`, "create active admin record from the owner's user account");
      step(`auth/${u.uid}`, 'claim role "user" -> "admin"');
      step(`users/${u.uid}`, "delete (push registrations included)");
      if (apply) {
        await db
          .collection(C.admins)
          .doc(u.uid)
          .set({
            name: (d.name as string | undefined) ?? u.displayName ?? "Owner",
            email: ((d.email as string | undefined) ?? u.email ?? "").toLowerCase(),
            phone: (d.phone as string | null | undefined) ?? null,
            status: "active",
            invitedBy: null,
            invitedAt: null,
            inviteSentAt: null,
            activatedAt: now,
          });
        await auth.setCustomUserClaims(u.uid, { ...u.customClaims, role: "admin" });
        await auth.revokeRefreshTokens(u.uid);
        await db.recursiveDelete(ref);
      }
      await addMember(u.uid);
      continue;
    }

    // Everyone else becomes staff with a username.
    const update: Record<string, unknown> = deletes(d, old);
    if (d.status === "suspended") update.status = "disabled";
    if (!d.username) {
      const email = ((d.email as string | undefined) ?? u.email ?? "").toLowerCase();
      const found = await freeUsername(email.split("@")[0] ?? "", takenUsernames);
      if (!found) {
        report.problems.push(
          `users/${u.uid}: no free username from "${email}"; set one on the website`,
        );
      } else {
        update.username = found;
        if (d.email === undefined) update.email = email || null;
        step(`auth/${u.uid}`, `sign-in address -> ${staffLoginEmail(found)}`);
        if (apply) await auth.updateUser(u.uid, { email: staffLoginEmail(found) });
      }
    }
    if (Object.keys(update).length > 0) {
      step(`users/${u.uid}`, `update ${keysOf(update)}`);
      if (apply) await ref.update(update);
    }
    const active = (update.status ?? d.status) === "active";
    if (active) {
      await addMember(u.uid);
    } else if (apply) {
      await auth.updateUser(u.uid, { disabled: true });
    }
  }

  // 2. Devices: removed ones are deleted (no restore window in v3), the rest
  // lose their owner and take the admin label as their name.
  const labels = new Map((await db.collection(C.allowedDevices).get()).docs.map((a) => [a.id, a]));
  for (const dev of (await db.collection(C.devices).get()).docs) {
    const d = dev.data();
    if (d.removedAt) {
      step(`devices/${dev.id}`, "delete with its history (it was removed in v2)");
      if (apply) await deleteDeviceData(dev.id);
      continue;
    }
    const update: Record<string, unknown> = deletes(d, [
      "ownerUid",
      "removedAt",
      "purgeAfter",
      "removedBy",
      "removedLabel",
    ]);
    if (d.sensorType === undefined) update.sensorType = sensorOf(null);
    const label = labels.get(dev.id)?.get("label") as string | undefined;
    if (label && d.nickname === defaultNickname(dev.id)) update.nickname = label;
    if (Object.keys(update).length > 0) {
      step(`devices/${dev.id}`, `update ${keysOf(update)}`);
      if (apply) await dev.ref.update(update);
    }
  }
  for (const [id, a] of labels) {
    if ("label" in (a.data() ?? {})) {
      step(`allowed_devices/${id}`, "delete label");
      if (apply) await a.ref.update({ label: del() });
    }
  }
  for (const h of (await db.collection(C.deviceHealth).get()).docs) {
    if ("ownerUid" in h.data()) {
      step(`device_health/${h.id}`, "delete ownerUid");
      if (apply) await h.ref.update({ ownerUid: del() });
    }
  }

  // 3. History: no owner, no notes.
  for (const col of [C.problems, C.readings]) {
    const snap = await db.collection(col).get();
    const stale = snap.docs.filter((p) => "ownerUid" in p.data() || "note" in p.data());
    if (stale.length === 0) continue;
    step(col, `delete ownerUid/note on ${stale.length} docs`);
    if (apply) {
      for (let i = 0; i < stale.length; i += 400) {
        const batch = db.batch();
        for (const p of stale.slice(i, i + 400))
          batch.update(p.ref, deletes(p.data(), ["ownerUid", "note"]));
        await batch.commit();
      }
    }
  }

  // 4. One pipeline: the owner's, if any.
  const pipelines = (await db.collection(C.pipelines).get()).docs.filter(
    (p) => p.id !== PIPELINE_DOC,
  );
  const ownerPipe = pipelines.find((p) => p.id === ownerUid);
  if (ownerPipe && !(await db.collection(C.pipelines).doc(PIPELINE_DOC).get()).exists) {
    step(`pipelines/${PIPELINE_DOC}`, `copy from pipelines/${ownerPipe.id}`);
    if (apply) await db.collection(C.pipelines).doc(PIPELINE_DOC).set(ownerPipe.data());
  }
  for (const p of pipelines) {
    if (p.id !== ownerUid)
      report.problems.push(`pipelines/${p.id} belonged to another user; deleted`);
    step(`pipelines/${p.id}`, "delete");
    if (apply) await p.ref.delete();
  }

  // 5. Records v3 no longer has.
  for (const col of ["admin_audit", "password_resets"]) {
    const snap = await db.collection(col).get();
    if (snap.empty) continue;
    step(col, `delete ${snap.size} docs`);
    if (apply) await db.recursiveDelete(db.collection(col));
  }

  // 6. Live channel: no owner fields; sensor and cutoffs mirrored again.
  type Nodes = Record<string, Record<string, unknown>>;
  const live = ((await rtdb.ref("live").get()).val() ?? {}) as Nodes;
  const state = ((await rtdb.ref("state").get()).val() ?? {}) as Nodes;
  const owned = (n: Record<string, unknown> | undefined) =>
    !!n && ("ownerUid" in n || "removed" in n);
  const ids = [...new Set([...Object.keys(live), ...Object.keys(state)])].filter(
    (id) => owned(live[id]) || owned(state[id]) || !("sensorType" in (state[id] ?? {})),
  );
  if (ids.length > 0) {
    step("live, state", `drop ownerUid/removed and mirror sensor on ${ids.length} devices`);
    if (apply) {
      const patch: Record<string, null> = {};
      for (const id of ids) {
        for (const f of ["ownerUid", "removed"]) {
          patch[`live/${id}/${f}`] = null;
          patch[`state/${id}/${f}`] = null;
        }
      }
      await rtdb.ref().update(patch);
      for (const id of ids) await mirrorDevice(id);
    }
  }
  if (!ownerUid)
    report.problems.push("no ownerUid given: nobody was made admin from a user account");
  return report;
}
