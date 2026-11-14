// One-off v1 -> v2 data migration (KICKOFF.md stage 2). Not deployed: run by
// tools/migrate-v2.ts (dry run by default) and by the emulator tests. Safe to run
// twice: every step checks the current shape first.
import { getAuth, type UserRecord } from "firebase-admin/auth";
import { FieldValue } from "firebase-admin/firestore";
import { C, db, ts } from "../lib/db";
import { normalizePhMobile } from "../lib/userInput";
import { DEFAULT_ALERT_PREFS } from "../admin/users";

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

/** "set a, b; delete c" for the report. */
function describeUpdate(update: Record<string, unknown>): string {
  const del = FieldValue.delete();
  const keys = Object.keys(update).sort();
  const sets = keys.filter((k) => !(update[k] instanceof FieldValue && del.isEqual(update[k])));
  const dels = keys.filter((k) => !sets.includes(k));
  return [
    sets.length ? `set ${sets.join(", ")}` : "",
    dels.length ? `delete ${dels.join(", ")}` : "",
  ]
    .filter(Boolean)
    .join("; ");
}

/** Plans (and with apply: true performs) the migration. */
export async function migrateV2(opts: {
  apply: boolean;
  nowMs?: number;
}): Promise<MigrationReport> {
  const { apply } = opts;
  const now = ts(opts.nowMs ?? Date.now());
  const report: MigrationReport = { applied: apply, steps: [], problems: [] };
  const step = (target: string, change: string) => report.steps.push({ target, change });
  const auth = getAuth();

  for (const u of await allAuthUsers()) {
    const role = u.customClaims?.role;

    // Admins: keep the claim, add the admins/{uid} record (D23, D40).
    if (role === "admin") {
      const ref = db.collection(C.admins).doc(u.uid);
      if (!(await ref.get()).exists) {
        step(`admins/${u.uid}`, "create active admin record");
        if (apply) {
          await ref.set({
            name: u.displayName ?? u.email ?? "Admin",
            email: (u.email ?? "").toLowerCase(),
            status: "active",
            invitedBy: null,
            invitedAt: null,
            inviteSentAt: null,
            activatedAt: now,
          });
        }
      }
      continue;
    }

    // Users: role "client" (v1) becomes "user" (D21).
    if (role !== "client" && role !== "user") continue;
    if (role === "client") {
      step(`auth/${u.uid}`, 'claim role "client" -> "user"');
      if (apply) await auth.setCustomUserClaims(u.uid, { ...u.customClaims, role: "user" });
    }

    const ref = db.collection(C.users).doc(u.uid);
    const doc = await ref.get();
    const d = doc.data() ?? {};
    const phone = normalizePhMobile(d.phone) ?? (typeof d.phone === "string" ? d.phone : null);
    const owned = await db.collection(C.devices).where("ownerUid", "==", u.uid).count().get();
    const update: Record<string, unknown> = {};
    if (d.role !== "user") update.role = "user";
    if (typeof d.name !== "string")
      update.name = d.displayName ?? u.displayName ?? u.email ?? "User";
    if (d.email === undefined) update.email = (u.email ?? "").toLowerCase();
    if (phone && phone !== d.phone) update.phone = phone;
    if (typeof d.passwordSet !== "boolean") {
      update.passwordSet = u.providerData.some((p) => p.providerId === "password");
    }
    if (d.deviceCount !== owned.data().count) update.deviceCount = owned.data().count;
    if (d.alertPrefs === undefined) update.alertPrefs = DEFAULT_ALERT_PREFS;
    if (d.status === undefined) update.status = "active";
    for (const f of ["suspendedAt", "purgeAfter", "deletionRequestedAt"]) {
      if (d[f] === undefined) update[f] = null;
    }
    if (d.createdAt === undefined) update.createdAt = now;
    for (const f of ["displayName", "mustChangePassword", "lastCalibrateAt"]) {
      if (f in d) update[f] = FieldValue.delete();
    }
    if (Object.keys(update).length > 0) {
      step(`users/${u.uid}`, describeUpdate(update));
      if (apply) await ref.set(update, { merge: true });
    }

    if (!phone) {
      report.problems.push(`users/${u.uid} has no valid mobile number; add it on the website`);
    } else {
      const idx = db.collection(C.phoneIndex).doc(phone);
      const owner = (await idx.get()).get("uid") as string | undefined;
      if (owner && owner !== u.uid) {
        report.problems.push(`phone_index/${phone} belongs to another account`);
      } else if (!owner) {
        step(`phone_index/${phone}`, "create");
        if (apply) await idx.set({ uid: u.uid });
      }
    }
  }

  // Devices: GPS fields renamed (section 6), manual pin added (D25), pause removed (D29).
  for (const dev of (await db.collection(C.devices).get()).docs) {
    const d = dev.data();
    const update: Record<string, unknown> = {};
    if ("lat" in d || "lng" in d) {
      if (d.gpsLat === undefined) update.gpsLat = d.lat ?? null;
      if (d.gpsLng === undefined) update.gpsLng = d.lng ?? null;
      update.lat = FieldValue.delete();
      update.lng = FieldValue.delete();
    }
    if (d.gpsLat === undefined && !("lat" in d)) update.gpsLat = null;
    if (d.gpsLng === undefined && !("lng" in d)) update.gpsLng = null;
    if (d.manualLat === undefined) update.manualLat = null;
    if (d.manualLng === undefined) update.manualLng = null;
    if ("pausedUntil" in d) update.pausedUntil = FieldValue.delete();
    if (Object.keys(update).length > 0) {
      step(`devices/${dev.id}`, describeUpdate(update));
      if (apply) await dev.ref.update(update);
    }
  }

  for (const h of (await db.collection(C.deviceHealth).get()).docs) {
    if ("lastBatteryLogAt" in h.data()) {
      step(`device_health/${h.id}`, "delete lastBatteryLogAt");
      if (apply) await h.ref.update({ lastBatteryLogAt: FieldValue.delete() });
    }
  }

  // The single-client record (D10) has no v2 reader.
  const system = db.collection("config").doc("system");
  if ((await system.get()).exists) {
    step("config/system", "delete");
    if (apply) await system.delete();
  }

  return report;
}
