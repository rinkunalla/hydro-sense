// Admin audit log and notices to the other admins (CLAUDE.md D42). Entries are
// written only here and are never updated or deleted by a person (rules deny it);
// the TTL policy removes them after AUDIT_TTL_DAYS.
import { onCall } from "firebase-functions/https";
import { AUDIT_LIST_LIMIT, AUDIT_TTL_DAYS, RESTORE_WINDOW_DAYS } from "../config";
import { requireAdmin } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { providers } from "../lib/providers";
import { formatManila } from "../lib/time";

const DAY_MS = 86_400_000;

export type AuditAction =
  | "user_deleted"
  | "user_restored"
  | "device_removed"
  | "device_restored"
  | "device_reassigned"
  | "admin_removed"
  | "deletion_requested";

/** "{actor} {words} {target}" (docs/UI_UX_SPEC.md section 7, admin notice). */
const WORDS: Record<AuditAction, string> = {
  user_deleted: "deleted the user",
  user_restored: "restored the user",
  device_removed: "removed",
  device_restored: "restored",
  device_reassigned: "reassigned",
  admin_removed: "removed the admin",
  deletion_requested: "asked to delete the account of",
};

/** Actions that can be undone on the website until the purge date. */
const RESTORABLE: ReadonlySet<AuditAction> = new Set(["user_deleted", "device_removed"]);

export interface AuditInput {
  /** Who did it: an admin, or the user for deletion_requested. Stored as adminUid. */
  adminUid: string;
  action: AuditAction;
  targetId: string;
  targetName: string;
  /** Set when the actor is not an admin (a user's own request). */
  actor?: { name: string; email: string | null };
  nowMs?: number;
}

async function actorOf(input: AuditInput): Promise<{ name: string; email: string | null }> {
  if (input.actor) return input.actor;
  const snap = await db.collection(C.admins).doc(input.adminUid).get();
  const email = (snap.get("email") as string | undefined) ?? null;
  return { name: (snap.get("name") as string | undefined) ?? email ?? "An admin", email };
}

/** Subject and body of the notice to the other admins. */
export function auditNotice(
  actorName: string,
  action: AuditAction,
  targetName: string,
  nowMs: number,
): { subject: string; text: string } {
  const what =
    action === "deletion_requested"
      ? `${targetName} asked to delete their account`
      : `${actorName} ${WORDS[action]} ${targetName}`;
  const lines = [`${what} on ${formatManila(nowMs)}.`];
  if (RESTORABLE.has(action)) {
    const until = formatManila(nowMs + RESTORE_WINDOW_DAYS * DAY_MS);
    lines.push("", `Any admin can restore it on the website until ${until}.`);
  }
  if (action === "deletion_requested") {
    lines.push("", "Delete the user on the website (Users) to suspend the account.");
  }
  return { subject: `Hydro Sense: ${what}`, text: lines.join("\n") };
}

/**
 * Writes the entry, then emails every other active admin. A failed email is logged
 * and never undoes the action (the entry is the record).
 */
export async function audit(input: AuditInput): Promise<void> {
  const nowMs = input.nowMs ?? Date.now();
  const actor = await actorOf(input);
  await db.collection(C.adminAudit).add({
    at: ts(nowMs),
    adminUid: input.adminUid,
    adminEmail: actor.email,
    action: input.action,
    targetId: input.targetId,
    targetName: input.targetName,
    expireAt: ts(nowMs + AUDIT_TTL_DAYS * DAY_MS),
  });

  const notice = auditNotice(actor.name, input.action, input.targetName, nowMs);
  const admins = await db.collection(C.admins).where("status", "==", "active").get();
  for (const a of admins.docs) {
    const to = a.get("email") as string | undefined;
    if (a.id === input.adminUid || !to) continue;
    try {
      await providers().email.send(to, notice.subject, notice.text);
    } catch (e) {
      await logError({ source: "audit", code: "EMAIL_FAILED", message: String(e), nowMs });
    }
  }
}

export const listAdminAudit = onCall(async (request) => {
  await requireAdmin(request);
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
