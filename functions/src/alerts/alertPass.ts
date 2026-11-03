import { ALERT_DAILY_CAP, ALERT_SEND_LEASE_S } from "../config";
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

export interface AlertPassResult {
  sent: AlertItem[];
  sms: "sent" | "digest" | "capped" | "failed" | "none";
  email: "sent" | "digest" | "capped" | "failed" | "none";
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

type CapClaim = "send" | "digest" | "capped";

/** Counts one message against today's per-channel cap (CLAUDE.md section 7 rule 8). */
async function claimCap(channel: "sms" | "email", nowMs: number): Promise<CapClaim> {
  const ref = db.collection(C.alertDaily).doc(manilaDateKey(nowMs));
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const count = (snap.get(`${channel}Count`) as number | undefined) ?? 0;
    if (count < ALERT_DAILY_CAP) {
      tx.set(ref, { [`${channel}Count`]: count + 1 }, { merge: true });
      return "send";
    }
    if (snap.get(`${channel}DigestSent`) !== true) {
      tx.set(ref, { [`${channel}DigestSent`]: true }, { merge: true });
      return "digest";
    }
    return "capped";
  });
}

async function releaseCap(channel: "sms" | "email", nowMs: number) {
  const ref = db.collection(C.alertDaily).doc(manilaDateKey(nowMs));
  await db.runTransaction(async (tx) => {
    const count = ((await tx.get(ref)).get(`${channel}Count`) as number | undefined) ?? 0;
    if (count > 0) tx.set(ref, { [`${channel}Count`]: count - 1 }, { merge: true });
  });
}

async function deliver(
  channel: "sms" | "email",
  to: string | null,
  items: AlertItem[],
  nowMs: number,
): Promise<AlertPassResult["sms"]> {
  const code = channel === "sms" ? "SMS_FAILED" : "EMAIL_FAILED";
  if (!to) {
    await logError({ source: SOURCE, code, message: "no recipient", nowMs });
    return "failed";
  }
  const claim = await claimCap(channel, nowMs);
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
    if (claim === "send") await releaseCap(channel, nowMs);
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

/** Evaluates every owned device and sends what is due as one SMS and one email. */
export async function runAlertPass(nowMs = Date.now()): Promise<AlertPassResult> {
  const none: AlertPassResult = { sent: [], sms: "none", email: "none" };
  const system = await db.collection(C.config).doc("system").get();
  const clientUid = system.get("clientUid") as string | undefined;
  if (!clientUid) return none;

  const [devices, health, active] = await Promise.all([
    db.collection(C.devices).where("ownerUid", "==", clientUid).get(),
    db.collection(C.deviceHealth).where("ownerUid", "==", clientUid).get(),
    db.collection(C.alertState).where("active", "==", true).get(),
  ]);
  const healthById = new Map(health.docs.map((d) => [d.id, d.data()]));
  // Only active states can change without a fault, so healthy devices cost no reads.
  const activeIds = new Set(active.docs.map((d) => d.id));

  const claimed: Claimed[] = [];
  for (const dev of devices.docs) {
    const h = healthById.get(dev.id);
    if (!h) continue;
    const pausedUntilMs = ms(dev.get("pausedUntil"));
    if (pausedUntilMs !== null && pausedUntilMs > nowMs) continue;

    const view: DeviceView = {
      online: h.online === true,
      lastSeenMs: ms(h.lastSeen),
      flowStatus: (dev.get("flowStatus") as FlowStatus | null) ?? null,
      abnormalSinceMs: ms(dev.get("abnormalSince")),
      batteryPercent: (h.batteryPercent as number | null | undefined) ?? null,
      batteryFault: h.batteryFault === true,
    };
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
        if (c) claimed.push(c);
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
  }
  if (claimed.length === 0) return none;

  const user = await db.collection(C.users).doc(clientUid).get();
  const items = claimed.map((c) => c.item);
  const [sms, email] = await Promise.all([
    deliver("sms", (user.get("phone") as string | undefined) ?? null, items, nowMs),
    deliver("email", (user.get("email") as string | undefined) ?? null, items, nowMs),
  ]);

  // A capped or digest channel counts as handled; only real failures on both skip the lock.
  const handled = sms !== "failed" || email !== "failed";
  await Promise.all(
    claimed.map((c) =>
      handled ? c.ref.set(fromState(c.next)) : c.ref.update({ sendingUntil: null }),
    ),
  );
  return { sent: handled ? items : [], sms, email };
}
