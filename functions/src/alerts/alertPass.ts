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
import { DIGEST_EMAIL, DIGEST_SMS, buildEmail, buildSms, type AlertItem } from "../lib/messages";
import type { FlowStatus } from "../lib/payload";
import { providers } from "../lib/providers";
import { manilaDateKey } from "../lib/time";

const SOURCE = "alerts";

interface Claimed {
  ref: FirebaseFirestore.DocumentReference;
  next: AlertState;
  item: AlertItem;
}

type Channel = "sms" | "email";
export type ChannelResult = "sent" | "digest" | "capped" | "failed";

export interface UserAlertResult {
  sent: AlertItem[];
  sms: ChannelResult;
  email: ChannelResult;
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

async function deliver(
  channel: Channel,
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

/** Evaluates one device's three families; failures are logged per device. */
async function evaluateDevice(
  dev: FirebaseFirestore.QueryDocumentSnapshot,
  h: FirebaseFirestore.DocumentData,
  activeIds: Set<string>,
  nowMs: number,
): Promise<Claimed[]> {
  const view: DeviceView = {
    online: h.online === true,
    lastSeenMs: ms(h.lastSeen),
    flowStatus: (dev.get("flowStatus") as FlowStatus | null) ?? null,
    abnormalSinceMs: ms(dev.get("abnormalSince")),
    batteryPercent: (h.batteryPercent as number | null | undefined) ?? null,
    batteryFault: h.batteryFault === true,
  };
  const out: Claimed[] = [];
  for (const family of FAMILIES) {
    const cond = conditionFor(family, view, nowMs);
    if (cond.kind === "skip") continue;
    if (cond.kind !== "fault" && !activeIds.has(`${dev.id}__${family}`)) continue;
    try {
      const c = await evaluate(
        dev.id,
        family,
        cond,
        view,
        dev.get("nickname") as string,
        h.lowVoltageSleep === true,
        nowMs,
      );
      if (c) out.push(c);
    } catch (e) {
      await logError({
        source: SOURCE,
        code: "INTERNAL",
        message: String(e),
        deviceId: dev.id,
        nowMs,
      });
    }
  }
  return out;
}

/**
 * Evaluates every assigned device and sends what is due as one SMS and one email
 * per owner. Unassigned and removed devices and suspended users send nothing.
 */
export async function runAlertPass(nowMs = Date.now()): Promise<AlertPassResult> {
  const result: AlertPassResult = { sent: [], users: {} };
  const [devices, health, active] = await Promise.all([
    db.collection(C.devices).where("ownerUid", "!=", null).get(),
    db.collection(C.deviceHealth).where("ownerUid", "!=", null).get(),
    db.collection(C.alertState).where("active", "==", true).get(),
  ]);
  const healthById = new Map(health.docs.map((d) => [d.id, d.data()]));
  // Only active states can change without a fault, so healthy devices cost no reads.
  const activeIds = new Set(active.docs.map((d) => d.id));

  const byOwner = new Map<string, FirebaseFirestore.QueryDocumentSnapshot[]>();
  for (const dev of devices.docs) {
    if (dev.get("removedAt")) continue;
    const owner = dev.get("ownerUid") as string;
    byOwner.set(owner, [...(byOwner.get(owner) ?? []), dev]);
  }
  if (byOwner.size === 0) return result;
  const owners = [...byOwner.keys()];
  const users = await db.getAll(...owners.map((u) => db.collection(C.users).doc(u)));

  for (const user of users) {
    if (!user.exists || user.get("status") !== "active") continue;
    const claimed: Claimed[] = [];
    for (const dev of byOwner.get(user.id)!) {
      const h = healthById.get(dev.id);
      if (h) claimed.push(...(await evaluateDevice(dev, h, activeIds, nowMs)));
    }
    if (claimed.length === 0) continue;

    const items = claimed.map((c) => c.item);
    const [sms, email] = await Promise.all([
      deliver("sms", user.id, (user.get("phone") as string | undefined) ?? null, items, nowMs),
      deliver("email", user.id, (user.get("email") as string | undefined) ?? null, items, nowMs),
    ]);
    // A capped or digest channel counts as handled; only real failures on both skip the lock.
    const handled = sms !== "failed" || email !== "failed";
    await Promise.all(
      claimed.map((c) =>
        handled ? c.ref.set(fromState(c.next)) : c.ref.update({ sendingUntil: null }),
      ),
    );
    result.users[user.id] = { sent: handled ? items : [], sms, email };
    if (handled) result.sent.push(...items);
  }
  return result;
}
