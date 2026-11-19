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

/** "off": switched off by the user; "none": nothing for this channel (no No Flow item
 *  for SMS, or no app installation registered for push). Neither counts as a failure. */
export type ChannelResult = "sent" | "digest" | "capped" | "failed" | "off" | "none";

export interface UserAlertResult {
  sent: AlertItem[];
  push: ChannelResult;
  sms: ChannelResult;
  email: ChannelResult;
}

export interface AlertPrefs {
  push: boolean;
  sms: boolean;
  email: boolean;
}

/** Defaults (D27): push on, SMS on, email off. */
export function prefsOf(user: FirebaseFirestore.DocumentSnapshot): AlertPrefs {
  const p = (user.get("alertPrefs") ?? {}) as Partial<AlertPrefs>;
  return { push: p.push !== false, sms: p.sms !== false, email: p.email === true };
}

/** What each channel carries (D27): push and email everything, SMS only No Flow. */
export function itemsFor(channel: Channel, items: readonly AlertItem[]): AlertItem[] {
  return channel === "sms" ? items.filter((i) => i.type === "flow_none") : [...items];
}

export interface AlertPassResult {
  /** Every item handled in this pass, across users. */
  sent: AlertItem[];
  /** Only users who had something due. */
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
 * the project-wide ceiling (CLAUDE.md section 7 rule 8, D30). One transaction.
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
  if (!to) {
    await logError({ source: SOURCE, code, message: "no recipient", nowMs });
    return "failed";
  }
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
 * Evaluates every assigned device and sends what is due as one SMS and one email
 * per owner. Unassigned and removed devices and suspended users send nothing.
 * Reads the live nodes the monitor already has (D48); Firestore is read only for
 * owners and the nicknames of devices with something due.
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

  const byOwner = new Map<string, { id: string; l: Live; due: ReturnType<typeof dueFamilies> }[]>();
  for (const [id, l] of live) {
    if (!l.ownerUid || l.removed) continue;
    const due = dueFamilies(id, l, activeIds, nowMs);
    if (due.length === 0) continue;
    byOwner.set(l.ownerUid, [...(byOwner.get(l.ownerUid) ?? []), { id, l, due }]);
  }
  if (byOwner.size === 0) return result;
  const owners = [...byOwner.keys()];
  const dueIds = [...byOwner.values()].flat().map((d) => d.id);
  const [users, devices] = await Promise.all([
    db.getAll(...owners.map((u) => db.collection(C.users).doc(u))),
    db.getAll(...dueIds.map((id) => db.collection(C.devices).doc(id))),
  ]);
  const deviceById = new Map(devices.map((d) => [d.id, d]));

  for (const user of users) {
    if (!user.exists || user.get("status") !== "active") continue;
    const claimed: Claimed[] = [];
    for (const { id, l, due } of byOwner.get(user.id)!) {
      const dev = deviceById.get(id);
      // Firestore is the source of truth for owner and removal; /live is a mirror.
      if (!dev?.exists || dev.get("ownerUid") !== user.id || dev.get("removedAt")) continue;
      claimed.push(...(await evaluateDevice(id, l, due, dev.get("nickname") as string, nowMs)));
    }
    if (claimed.length === 0) continue;

    const items = claimed.map((c) => c.item);
    const prefs = prefsOf(user);
    const run = (channel: Channel, send: (list: AlertItem[]) => Promise<ChannelResult>) => {
      if (!prefs[channel]) return Promise.resolve<ChannelResult>("off");
      const list = itemsFor(channel, items);
      return list.length === 0 ? Promise.resolve<ChannelResult>("none") : send(list);
    };
    // Channels are independent (rule 9): one failing never blocks another.
    const [push, sms, email] = await Promise.all([
      run("push", (list) => deliverPush(user.id, list, nowMs)),
      run("sms", (list) =>
        deliver("sms", user.id, (user.get("phone") as string | undefined) ?? null, list, nowMs),
      ),
      run("email", (list) =>
        deliver("email", user.id, (user.get("email") as string | undefined) ?? null, list, nowMs),
      ),
    ]);
    // Only a send that failed on every channel it tried leaves the lock unset (rule 9),
    // so the next pass retries. All channels off: nothing is sent and the lock is set.
    const tried = [push, sms, email].filter((r) => r !== "off" && r !== "none");
    const handled = tried.length === 0 || tried.some((r) => r !== "failed");
    await Promise.all(
      claimed.map((c) =>
        handled ? c.ref.set(fromState(c.next)) : c.ref.update({ sendingUntil: null }),
      ),
    );
    result.users[user.id] = { sent: handled ? items : [], push, sms, email };
    if (handled) result.sent.push(...items);
  }
  return result;
}
