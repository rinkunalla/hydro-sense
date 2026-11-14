// The limits a device classifies with (D43). The weekly calibration keeps
// writing its automatic values to lowFlowCutoff/normalFlowCutoff; an owner's
// own limit (userNormalCutoff) wins while it is set, so "Use automatic" goes
// straight back to the latest automatic values.
import {
  STARTER_LOW_FLOW_CUTOFF,
  STARTER_NORMAL_FLOW_CUTOFF,
  USER_NORMAL_CUTOFF_MAX,
  USER_NORMAL_CUTOFF_MIN,
} from "../config";

export interface Cutoffs {
  lowFlowCutoff: number;
  normalFlowCutoff: number;
}

const num = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;

export function effectiveCutoffs(get: (field: string) => unknown): Cutoffs {
  const own = num(get("userNormalCutoff"));
  if (own !== null && own >= USER_NORMAL_CUTOFF_MIN && own <= USER_NORMAL_CUTOFF_MAX) {
    // The No Flow line stays at the starter value: an automatic one
    // (0.15 x mean) could sit above the owner's limit.
    return { lowFlowCutoff: STARTER_LOW_FLOW_CUTOFF, normalFlowCutoff: own };
  }
  const low = num(get("lowFlowCutoff")) ?? STARTER_LOW_FLOW_CUTOFF;
  const normal = num(get("normalFlowCutoff")) ?? STARTER_NORMAL_FLOW_CUTOFF;
  return low < normal
    ? { lowFlowCutoff: low, normalFlowCutoff: normal }
    : { lowFlowCutoff: STARTER_LOW_FLOW_CUTOFF, normalFlowCutoff: STARTER_NORMAL_FLOW_CUTOFF };
}
