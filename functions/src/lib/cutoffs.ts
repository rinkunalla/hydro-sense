// The limits a device classifies with. The weekly calibration keeps
// writing its automatic values to lowFlowCutoff/normalFlowCutoff; the admin's
// own limit (userNormalCutoff) wins while it is set, so "Use automatic" goes
// straight back to the latest automatic values. Starter values and the allowed
// range come from the device's sensor (D69).
import { SENSORS } from "../config";
import { sensorOf, starterCutoffs } from "./sensors";

export interface Cutoffs {
  lowFlowCutoff: number;
  normalFlowCutoff: number;
}

const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;

export function effectiveCutoffs(get: (field: string) => unknown): Cutoffs {
  const sensor = sensorOf(get("sensorType"));
  const starter = starterCutoffs(sensor);
  const own = num(get("userNormalCutoff"));
  const { userCutoffMin, userCutoffMax } = SENSORS[sensor];
  if (own !== null && own >= userCutoffMin && own <= userCutoffMax) {
    // The No Flow line stays at the starter value: an automatic one
    // (0.15 x mean) could sit above the admin's limit.
    return { lowFlowCutoff: starter.lowFlowCutoff, normalFlowCutoff: own };
  }
  const low = num(get("lowFlowCutoff")) ?? starter.lowFlowCutoff;
  const normal = num(get("normalFlowCutoff")) ?? starter.normalFlowCutoff;
  return low < normal ? { lowFlowCutoff: low, normalFlowCutoff: normal } : starter;
}
