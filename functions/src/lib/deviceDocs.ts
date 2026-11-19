// The starting shape of a device's two docs. Shared by
// registerDevice (first registration) and assignDevice (assigned before it).
import type { Timestamp } from "firebase-admin/firestore";
import { STARTER_LOW_FLOW_CUTOFF, STARTER_NORMAL_FLOW_CUTOFF } from "../config";
import { defaultNickname } from "./userInput";

export function newDeviceDoc(deviceId: string, ownerUid: string | null, now: Timestamp) {
  return {
    ownerUid,
    nickname: defaultNickname(deviceId),
    flowStatus: null,
    flowRate: null,
    gpsLat: null,
    gpsLng: null,
    manualLat: null,
    manualLng: null,
    lowFlowCutoff: STARTER_LOW_FLOW_CUTOFF,
    normalFlowCutoff: STARTER_NORMAL_FLOW_CUTOFF,
    userNormalCutoff: null,
    calibratedAt: null,
    abnormalSince: null,
    statusChangedAt: null,
    updatedAt: now,
  };
}

/** registeredAt null means "Not set up yet" until the device first registers. */
export function newHealthDoc(
  ownerUid: string | null,
  registeredAt: Timestamp | null,
  firmware: string | null,
) {
  return {
    ownerUid,
    online: false,
    lastSeen: null,
    batteryVoltage: null,
    batteryPercent: null,
    chargingStatus: null,
    recentVoltages: [],
    batteryFault: false,
    lowVoltageSleep: false,
    lastFlowLogAt: null,
    resetReason: null,
    registeredAt,
    firmware,
    rssi: null,
  };
}

/** What a new owner gets: everything the old owner set or caused is reset. */
export function ownerResetFields(deviceId: string) {
  return {
    nickname: defaultNickname(deviceId),
    manualLat: null,
    manualLng: null,
    lowFlowCutoff: STARTER_LOW_FLOW_CUTOFF,
    normalFlowCutoff: STARTER_NORMAL_FLOW_CUTOFF,
    userNormalCutoff: null,
    calibratedAt: null,
  };
}
