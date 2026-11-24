import { ALERT_DAILY_CAP, ALERT_SEND_LEASE_S, SMS_PROJECT_DAILY_CAP } from "../config";
import {
  EMPTY_STATE,
  FAMILIES,
  conditionFor,
  decide,
  sameState,
  type AlertState,
  type Condition,
  type DeviceView,
  type Family,
} from "../lib/alertLogic";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import {
  type AlertType,
  DIGEST_EMAIL,
  DIGEST_PUSH,
  DIGEST_SMS,
  buildEmail,
  buildPush,
  buildSms,
  type AlertItem,
} from "../lib/messages";
import type { Live } from "../lib/live";
import { readAllLive } from "../lib/liveStore";
import { providers } from "../lib/providers";
import { manilaDateKey } from "../lib/time";

const SOURCE = "alerts";

interface Claimed {
  ref: FirebaseFirestore.DocumentReference;
  next: AlertState;
  item: AlertItem;
}

type Channel = "push" | "sms" | "email";

/** "none": nothing for this channel (no SMS item, no contact, or no app
 *  installation registered for push). It never counts as a failure. */
export type ChannelResult = "sent" | "digest" | "capped" | "failed" | "none";

export interface UserAlertResult {
  sent: AlertItem[];
  push: ChannelResult;
  sms: ChannelResult;
  email: ChannelResult;
}

/** Alert types that go by SMS (D65); low battery never does. */
export const SMS_TYPES: ReadonlySet<AlertType> = new Set(["flow_none", "flow_low", "offline"]);

/** What each channel carries: push and email everything, SMS all but low battery. */
export function itemsFor(channel: Channel, items: readonly AlertItem[]): AlertItem[] {
  return channel === "sms" ? items.filter((i) => SMS_TYPES.has(i.type)) : [...items];
}

/** Someone who receives alerts: an active staff member or an active admin. */
export interface Recipient {
  uid: string;
  kind: "staff" | "admin";
  phone: string | null;
  email: string | null;
}

/** Every active member with the contacts the admin entered (D65). */
export async function alertRecipients(): Promise<Recipient[]> {
  const [staff, admins] = await Promise.all([
    db.collection(C.users).where("role", "==", "user").where("status", "==", "active").get(),
    db.collection(C.admins).where("status", "==", "active").get(),
  ]);
  const of = (d: FirebaseFirestore.QueryDocumentSnapshot, kind: Recipient["kind"]): Recipient => ({
    uid: d.id,
    kind,
    phone: (d.get("phone") as string | null | undefined) || null,
    email: (d.get("email") as string | null | undefined) || null,
  });
  return [...staff.docs.map((d) => of(d, "staff")), ...admins.docs.map((d) => of(d, "admin"))];
}

export interface AlertPassResult {
  /** Every item handled in this pass. */
  sent: AlertItem[];
  /** Per recipient, only when something was due. */
  users: Record<string, UserAlertResult>;
}

const toState = (d: FirebaseFirestore.DocumentData | undefined): AlertState => ({
  active: d?.active === true,
  lastSentAtMs: ms(d?.lastSentAt),
  lockedUntilMs: ms(d?.lockedUntil),
  lastType: d?.lastType ?? null,
  reminders: (d?.reminders as number | undefined) ?? 0,
  recoveredSinceMs: ms(d?.recoveredSince),
});

const fromState = (s: AlertState) => ({
  active: s.active,
  lastSentAt: s.lastSentAtMs === null ? null : ts(s.lastSentAtMs),
  lockedUntil: s.lockedUntilMs === null ? null : ts(s.lockedUntilMs),
  lastType: s.lastType,
  reminders: s.reminders,
  recoveredSince: s.recoveredSinceMs === null ? null : ts(s.recoveredSinceMs),
  sendingUntil: null,
});

export const alertStateRef = (deviceId: string, family: Family) =>
  db.collection(C.alertState).doc(`${deviceId}__${family}`);

/**
 * Applies the gate for one device + family inside a transaction. Returns a claimed
 * send (with a lease) or null. A live lease means another run is sending: skip.
 */
async function evaluate(
  deviceId: string,
  family: Family,
  cond: Condition,
  view: DeviceView,
  nickname: string,
  batteryEmpty: boolean,
  nowMs: number,
): Promise<Claimed | null> {
  const ref = alertStateRef(deviceId, family);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists && cond.kind !== "fault") return null;
    const leaseMs = ms(snap.get("sendingUntil"));
    if (leaseMs !== null && leaseMs > nowMs) return null;

    const state = snap.exists ? toState(snap.data()) : EMPTY_STATE;
    const d = decide(state, cond, nowMs);
    if (!d.send) {
      if (!sameState(state, d.next)) tx.set(ref, fromState(d.next));
      return null;
    }
    tx.set(ref, { ...fromState(state), sendingUntil: ts(nowMs + ALERT_SEND_LEASE_S * 1000) });
    const sinceMs =
      family === "flow"
        ? (view.abnormalSinceMs ?? nowMs)
        : family === "offline"
          ? (view.lastSeenMs ?? nowMs)
          : nowMs;
    return {
      ref,
      next: d.next,
      item: {
        deviceId,
        nickname,
        type: d.send.type,
        reminder: d.send.reminder,
        batteryPercent: view.batteryPercent,
        batteryEmpty: family === "offline" && batteryEmpty,
        sinceMs,
      },
    };
  });
}

type CapClaim = "send" | "digest" | "capped" | "project_capped";

const userDayRef = (uid: string, nowMs: number) =>
  db.collection(C.alertDaily).doc(`${manilaDateKey(nowMs)}__${uid}`);
const projectDayRef = (nowMs: number) => db.collection(C.alertDaily).doc(manilaDateKey(nowMs));

/**
 * Counts one message against the user's per-channel cap for today and, for SMS,
 * the project-wide ceiling. One transaction.
 */
async function claimCap(channel: Channel, uid: string, nowMs: number): Promise<CapClaim> {
  const userRef = userDayRef(uid, nowMs);
  const projectRef = projectDayRef(nowMs);
  return db.runTransaction(async (tx) => {
    const [user, project] = await Promise.all([tx.get(userRef), tx.get(projectRef)]);
    const projectSms = (project.get("smsCount") as number | undefined) ?? 0;
    if (channel === "sms" && projectSms >= SMS_PROJECT_DAILY_CAP) return "project_capped";

    const count = (user.get(`${channel}Count`) as number | undefined) ?? 0;
    let claim: CapClaim;
    if (count < ALERT_DAILY_CAP) {
      tx.set(userRef, { [`${channel}Count`]: count + 1 }, { merge: true });
      claim = "send";
    } else if (user.get(`${channel}DigestSent`) !== true) {
      tx.set(userRef, { [`${channel}DigestSent`]: true }, { merge: true });
      claim = "digest";
    } else {
      return "capped";
    }
    // A digest SMS is still an SMS: it counts toward the project ceiling.
    if (channel === "sms") tx.set(projectRef, { smsCount: projectSms + 1 }, { merge: true });
    return claim;
  });
}

async function releaseCap(channel: Channel, uid: string, nowMs: number) {
  const userRef = userDayRef(uid, nowMs);
  const projectRef = projectDayRef(nowMs);
  await db.runTransaction(async (tx) => {
    const [user, project] = await Promise.all([tx.get(userRef), tx.get(projectRef)]);
    const count = (user.get(`${channel}Count`) as number | undefined) ?? 0;
    if (count > 0) tx.set(userRef, { [`${channel}Count`]: count - 1 }, { merge: true });
    const projectSms = (project.get("smsCount") as number | undefined) ?? 0;
    if (channel === "sms" && projectSms > 0) {
      tx.set(projectRef, { smsCount: projectSms - 1 }, { merge: true });
    }
  });
}

const pushTokens = (uid: string) => db.collection(C.users).doc(uid).collection(C.pushTokens);

/** Push to every registered app installation of the user; stale IDs are deleted. */
async function deliverPush(uid: string, items: AlertItem[], nowMs: number): Promise<ChannelResult> {
  const fids = (await pushTokens(uid).get()).docs.map((d) => d.id);
  if (fids.length === 0) return "none";
  const claim = await claimCap("push", uid, nowMs);
  if (claim === "capped" || claim === "project_capped") return "capped";
  const msg = claim === "digest" ? DIGEST_PUSH : buildPush(items);
  try {
    const r = await providers().push.send(fids, msg.title, msg.body, { ...msg.data });
    if (r.stale.length > 0) {
      const batch = db.batch();
      for (const fid of r.stale) batch.delete(pushTokens(uid).doc(fid));
      await batch.commit();
    }
    if (r.sent === 0) {
      if (claim === "send") await releaseCap("push", uid, nowMs);
      return "none";
    }
  } catch (e) {
    if (claim === "send") await releaseCap("push", uid, nowMs);
    await logError({ source: SOURCE, code: "PUSH_FAILED", message: String(e), nowMs });
    return "failed";
  }
  if (claim === "digest") {
    await logError({ source: SOURCE, code: "ALERT_CAP_REACHED", message: "push cap", nowMs });
    return "digest";
  }
  return "sent";
}

async function deliver(
  channel: "sms" | "email",
  uid: string,
  to: string | null,
  items: AlertItem[],
  nowMs: number,
): Promise<ChannelResult> {
  const code = channel === "sms" ? "SMS_FAILED" : "EMAIL_FAILED";
  if (!to) return "none";
  const claim = await claimCap(channel, uid, nowMs);
  if (claim === "project_capped") {
    await logError({ source: SOURCE, code: "SMS_PROJECT_CAP_REACHED", message: "sms", nowMs });
    return "capped";
  }
  if (claim === "capped") return "capped";
  const p = providers();
  try {
    if (channel === "sms") {
      await p.sms.send(to, claim === "digest" ? DIGEST_SMS : buildSms(items));
    } else {
      const mail = claim === "digest" ? DIGEST_EMAIL : buildEmail(items);
      await p.email.send(to, mail.subject, mail.text);
    }
  } catch (e) {
    if (claim === "send") await releaseCap(channel, uid, nowMs);
    // logError scrubs any address or number the provider echoes back.
    await logError({ source: SOURCE, code, message: String(e), nowMs });
    return "failed";
  }
  if (claim === "digest") {
    await logError({ source: SOURCE, code: "ALERT_CAP_REACHED", message: `${channel} cap`, nowMs });
    return "digest";
  }
  return "sent";
}

const viewOf = (l: Live): DeviceView => ({
  online: l.online,
  lastSeenMs: l.lastSeen,
  flowStatus: l.flowStatus,
  abnormalSinceMs: l.abnormalSince,
  batteryPercent: l.batteryPercent,
  batteryFault: l.batteryFault,
});

/** The families of one device that need a transaction this pass (fault or active). */
function dueFamilies(id: string, l: Live, activeIds: Set<string>, nowMs: number) {
  const view = viewOf(l);
  const due: { family: Family; cond: Condition }[] = [];
  for (const family of FAMILIES) {
    const cond = conditionFor(family, view, nowMs);
    if (cond.kind === "skip") continue;
    if (cond.kind !== "fault" && !activeIds.has(`${id}__${family}`)) continue;
    due.push({ family, cond });
  }
  return due;
}

/** Evaluates one device's due families; failures are logged per device. */
async function evaluateDevice(
  id: string,
  l: Live,
  due: { family: Family; cond: Condition }[],
  nickname: string,
  nowMs: number,
): Promise<Claimed[]> {
  const out: Claimed[] = [];
  for (const { family, cond } of due) {
    try {
      const c = await evaluate(id, family, cond, viewOf(l), nickname, l.lowVoltageSleep, nowMs);
      if (c) out.push(c);
    } catch (e) {
      await logError({ source: SOURCE, code: "INTERNAL", message: String(e), deviceId: id, nowMs });
    }
  }
  return out;
}

/**
 * Evaluates every device and sends what is due as one push, one SMS and one
 * email per recipient (D65): every active staff member and admin, on the
 * channels they have contacts for. Each device's lock is claimed once, not per
 * recipient. Reads the live nodes the monitor already has; Firestore is read
 * only for the names of devices with something due and for the recipients.
 */
export async function runAlertPass(
  nowMs = Date.now(),
  liveNodes?: Map<string, Live>,
): Promise<AlertPassResult> {
  const result: AlertPassResult = { sent: [], users: {} };
  const [live, active] = await Promise.all([
    liveNodes ? Promise.resolve(liveNodes) : readAllLive(),
    db.collection(C.alertState).where("active", "==", true).get(),
  ]);
  // Only active states can change without a fault, so healthy devices cost no reads.
  const activeIds = new Set(active.docs.map((d) => d.id));

  const due = [...live]
    .map(([id, l]) => ({ id, l, due: dueFamilies(id, l, activeIds, nowMs) }))
    .filter((d) => d.due.length > 0);
  if (due.length === 0) return result;
  const devices = await db.getAll(...due.map((d) => db.collection(C.devices).doc(d.id)));

  const claimed: Claimed[] = [];
  for (const [k, { id, l, due: families }] of due.entries()) {
    const dev = devices[k]!;
    // A removed device has no record any more; its live node is about to go.
    if (!dev.exists) continue;
    claimed.push(...(await evaluateDevice(id, l, families, dev.get("nickname") as string, nowMs)));
  }
  if (claimed.length === 0) return result;

  const items = claimed.map((c) => c.item);
  const tried: ChannelResult[] = [];
  for (const r of await alertRecipients()) {
    const run = (channel: Channel, send: (list: AlertItem[]) => Promise<ChannelResult>) => {
      const list = itemsFor(channel, items);
      return list.length === 0 ? Promise.resolve<ChannelResult>("none") : send(list);
    };
    // Channels are independent (rule 9): one failing never blocks another.
    const [push, sms, email] = await Promise.all([
      r.kind === "staff"
        ? run("push", (list) => deliverPush(r.uid, list, nowMs))
        : Promise.resolve<ChannelResult>("none"),
      run("sms", (list) => deliver("sms", r.uid, r.phone, list, nowMs)),
      run("email", (list) => deliver("email", r.uid, r.email, list, nowMs)),
    ]);
    result.users[r.uid] = { sent: items, push, sms, email };
    tried.push(...[push, sms, email].filter((x) => x !== "none"));
  }
  // Only a send that failed on every channel it tried leaves the locks unset
  // (rule 9), so the next pass retries. Nobody to tell: the locks are set.
  const handled = tried.length === 0 || tried.some((x) => x !== "failed");
  await Promise.all(
    claimed.map((c) =>
      handled ? c.ref.set(fromState(c.next)) : c.ref.update({ sendingUntil: null }),
    ),
  );
  if (!handled) for (const u of Object.values(result.users)) u.sent = [];
  if (handled) result.sent.push(...items);
  return result;
}
