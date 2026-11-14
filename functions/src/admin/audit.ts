// Admin audit log and notices to the other admins (CLAUDE.md D42). Entries are
// written only here and are never updated or deleted by a person (rules deny it);
// the TTL policy removes them after AUDIT_TTL_DAYS.
import { onCall } from "firebase-functions/https";
import { AUDIT_LIST_LIMIT, AUDIT_TTL_DAYS } from "../config";
import { requireAdmin } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { providers } from "../lib/providers";

const DAY_MS = 86_400_000;

export type AuditAction =
  | "user_deleted"
  | "user_restored"
  | "device_removed"
  | "device_restored"
  | "device_reassigned"
  | "admin_removed"
  | "deletion_requested";

const WORDS: Record<AuditAction, string> = {
  user_deleted: "deleted the user",
  user_restored: "restored the user",
  device_removed: "removed the device",
  device_restored: "restored the device",
  device_reassigned: "reassigned the device",
  admin_removed: "removed the admin",
  deletion_requested: "asked to delete their account:",
};

export interface AuditInput {
  adminUid: string;
  action: AuditAction;
  targetId: string;
  targetName: string;
  nowMs?: number;
}

async function adminEmail(uid: string): Promise<string | null> {
  const snap = await db.collection(C.admins).doc(uid).get();
  return (snap.get("email") as string | undefined) ?? null;
}

/**
 * Writes the entry, then emails every other active admin. A failed email is logged
 * and never undoes the action (the entry is the record).
 */
export async function audit(input: AuditInput): Promise<void> {
  const nowMs = input.nowMs ?? Date.now();
  const actorEmail = await adminEmail(input.adminUid);
  await db.collection(C.adminAudit).add({
    at: ts(nowMs),
    adminUid: input.adminUid,
    adminEmail: actorEmail,
    action: input.action,
    targetId: input.targetId,
    targetName: input.targetName,
    expireAt: ts(nowMs + AUDIT_TTL_DAYS * DAY_MS),
  });

  const others = await db.collection(C.admins).where("status", "==", "active").get();
  const actor = actorEmail ?? "An admin";
  const text = [
    `${actor} ${WORDS[input.action]} ${input.targetName} (${input.targetId}).`,
    "",
    input.action === "user_deleted" || input.action === "device_removed"
      ? "It can be restored on the Hydro Sense website for 30 days."
      : "See the activity log on the Hydro Sense website (Account).",
  ].join("\n");
  for (const a of others.docs) {
    const to = a.get("email") as string | undefined;
    if (a.id === input.adminUid || !to) continue;
    try {
      await providers().email.send(to, "Hydro Sense admin activity", text);
    } catch (e) {
      await logError({ source: "audit", code: "EMAIL_FAILED", message: String(e), nowMs });
    }
  }
}

export const listAdminAudit = onCall(async (request) => {
  requireAdmin(request);
  const snap = await db
    .collection(C.adminAudit)
    .orderBy("at", "desc")
    .limit(AUDIT_LIST_LIMIT)
    .get();
  return {
    entries: snap.docs.map((d) => ({
      id: d.id,
      atMs: ms(d.get("at")),
      adminEmail: d.get("adminEmail") ?? null,
      action: d.get("action"),
      targetId: d.get("targetId"),
      targetName: d.get("targetName"),
    })),
  };
});
