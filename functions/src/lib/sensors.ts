// The flow sensor of a device (D69): its pulse factor, window and the
// starter limits the device classifies with until calibration or the admin
// sets others.
import { DEFAULT_SENSOR, SENSORS, type SensorType } from "../config";

export const isSensorType = (v: unknown): v is SensorType =>
  typeof v === "string" && Object.hasOwn(SENSORS, v);

/** A stored value, or the YF-S201 for devices made before v3. */
export const sensorOf = (v: unknown): SensorType => (isSensorType(v) ? v : DEFAULT_SENSOR);

/** What firmware 0.4.0 reads from every reply; older firmware ignores it. */
export const sensorReply = (sensor: SensorType) => ({
  pulsesPerLpm: SENSORS[sensor].pulsesPerLpm,
  flowWindowS: SENSORS[sensor].flowWindowS,
});

export const starterCutoffs = (sensor: SensorType) => ({
  lowFlowCutoff: SENSORS[sensor].starterLow,
  normalFlowCutoff: SENSORS[sensor].starterNormal,
});
