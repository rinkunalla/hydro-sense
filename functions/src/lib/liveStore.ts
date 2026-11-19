// Reads and writes the Realtime Database nodes of the live channel (D48).
// The Realtime Database drops null values, so every read fills in defaults.
import { STARTER_LOW_FLOW_CUTOFF, STARTER_NORMAL_FLOW_CUTOFF } from "../config";
import { effectiveCutoffs } from "./cutoffs";
import { C, db, liveRef, rtdb, stateRef } from "./db";
import { emptyLive, PROBLEM_TYPES, type Live, type ProblemType, type State } from "./live";

type Raw = Record<string, unknown> | null | undefined;

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);

export function toLive(raw: Raw): Live {
  const r = raw ?? {};
  const base = emptyLive(str(r.ownerUid));
  return {
    ...base,
    removed: r.removed === true,
    online: r.online === true,
    lastSeen: num(r.lastSeen),
    flowStatus: (str(r.flowStatus) as Live["flowStatus"]) ?? null,
    flowRate: num(r.flowRate),
    abnormalSince: num(r.abnormalSince),
    statusChangedAt: num(r.statusChangedAt),
    batteryPercent: num(r.batteryPercent),
    chargingStatus: (str(r.chargingStatus) as Live["chargingStatus"]) ?? null,
    batteryFault: r.batteryFault === true,
    lowVoltageSleep: r.lowVoltageSleep === true,
    heartbeatS: num(r.heartbeatS),
  };
}

export function toState(raw: Raw): State & { known: boolean } {
  const r = raw ?? {};
  const openRaw = (r.open ?? {}) as Record<string, unknown>;
  const open: Partial<Record<ProblemType, string>> = {};
  for (const t of PROBLEM_TYPES) {
    const id = str(openRaw[t]);
    if (id) open[t] = id;
  }
  return {
    known: r.known === true,
    ownerUid: str(r.ownerUid),
    removed: r.removed === true,
    tokenHash: str(r.tokenHash),
    lowFlowCutoff: num(r.lowFlowCutoff) ?? STARTER_LOW_FLOW_CUTOFF,
    normalFlowCutoff: num(r.normalFlowCutoff) ?? STARTER_NORMAL_FLOW_CUTOFF,
    recentVoltages: Array.isArray(r.recentVoltages)
      ? (r.recentVoltages as unknown[]).filter((v): v is number => typeof v === "number")
      : [],
    lastSampleAt: num(r.lastSampleAt),
    gpsLat: num(r.gpsLat),
    gpsLng: num(r.gpsLng),
    firmware: str(r.firmware),
    seriesDay: str(r.seriesDay),
    seriesMinute: str(r.seriesMinute),
    seriesPeak: num(r.seriesPeak),
    open,
  };
}

export async function readLive(id: string): Promise<Live> {
  return toLive((await liveRef(id).get()).val());
}

export async function readState(id: string) {
  return toState((await stateRef(id).get()).val());
}

/** Every /live node at once, for the monitor and the admin device list. */
export async function readAllLive(): Promise<Map<string, Live>> {
  const all = ((await rtdb.ref("live").get()).val() ?? {}) as Record<string, Raw>;
  return new Map(Object.entries(all).map(([id, raw]) => [id, toLive(raw)]));
}

/**
 * Copies a device's owner, removal and effective cutoffs from Firestore into
 * /state and /live, and its token hash from device_secrets. Returns false when
 * the device has no Firestore record (its nodes are then deleted). Called by
 * every server path that changes those fields, and by the devices trigger for
 * the owner's own writes (userNormalCutoff, D43).
 */
export async function mirrorDevice(id: string): Promise<boolean> {
  const [device, secret] = await Promise.all([
    db.collection(C.devices).doc(id).get(),
    db.collection(C.deviceSecrets).doc(id).get(),
  ]);
  if (!device.exists) {
    await rtdb.ref().update({ [`live/${id}`]: null, [`state/${id}`]: null });
    return false;
  }
  const ownerUid = (device.get("ownerUid") as string | null | undefined) ?? null;
  const removed = !!device.get("removedAt");
  const cut = effectiveCutoffs((f) => device.get(f));
  await rtdb.ref().update({
    [`state/${id}/known`]: true,
    [`state/${id}/ownerUid`]: ownerUid,
    [`state/${id}/removed`]: removed,
    [`state/${id}/tokenHash`]: (secret.get("tokenHash") as string | undefined) ?? null,
    [`state/${id}/lowFlowCutoff`]: cut.lowFlowCutoff,
    [`state/${id}/normalFlowCutoff`]: cut.normalFlowCutoff,
    [`state/${id}/gpsLat`]: (device.get("gpsLat") as number | null | undefined) ?? null,
    [`state/${id}/gpsLng`]: (device.get("gpsLng") as number | null | undefined) ?? null,
    [`live/${id}/ownerUid`]: ownerUid,
    [`live/${id}/removed`]: removed,
  });
  return true;
}

/** Forgets the open problem IDs (their records were deleted with the history). */
export const clearOpenProblems = (id: string) => stateRef(id).child("open").remove();

/** Deletes the device's nodes (purge). */
export const deleteLiveNodes = (id: string) =>
  rtdb.ref().update({ [`live/${id}`]: null, [`state/${id}`]: null, [`series/${id}`]: null });

/** Today's per-minute series goes with the rest of the history (reassign, D20). */
export const clearSeries = (id: string) => rtdb.ref(`series/${id}`).remove();
