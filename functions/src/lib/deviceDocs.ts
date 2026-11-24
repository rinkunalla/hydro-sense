// The starting shape of a device's two docs, made when the admin adds its ID
// (v3: every device belongs to the organization, D62). registeredAt null
// means "Not set up yet" until the device first registers.
import type { Timestamp } from "firebase-admin/firestore";
import type { SensorType } from "../config";
import { starterCutoffs } from "./sensors";
import { defaultNickname } from "./userInput";

export function newDeviceDoc(
  deviceId: string,
  now: Timestamp,
  opts: { name?: string | null; sensorType: SensorType },
) {
  return {
    nickname: opts.name ?? defaultNickname(deviceId),
    sensorType: opts.sensorType,
    flowStatus: null,
    flowRate: null,
    gpsLat: null,
    gpsLng: null,
    manualLat: null,
    manualLng: null,
    ...starterCutoffs(opts.sensorType),
    userNormalCutoff: null,
    calibratedAt: null,
    abnormalSince: null,
    statusChangedAt: null,
    addedAt: now,
    updatedAt: now,
  };
}

export function newHealthDoc(registeredAt: Timestamp | null, firmware: string | null) {
  return {
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
