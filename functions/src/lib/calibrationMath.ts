import {
  CALIBRATE_FALLBACK_LOW_OF_MEAN,
  CALIBRATE_FALLBACK_NORMAL_OF_MEAN,
  CALIBRATE_LOW_MIN,
  CALIBRATE_MIN_MEAN,
  CALIBRATE_MIN_SAMPLES,
  CALIBRATE_NORMAL_MAX_OF_MEAN,
  CALIBRATE_NORMAL_MIN,
} from "../config";

export interface Cutoffs {
  lowFlowCutoff: number;
  normalFlowCutoff: number;
}

export interface FlowStats {
  samples: number;
  mean: number;
  p10: number;
  p50: number;
}

/**
 * One average per bucket. Uploads are event-driven, so averaging per bucket stops
 * bursts of status changes from outweighing steady periods.
 */
export function bucketAverages(
  rows: readonly { tsMs: number; flowRate: number }[],
  bucketS: number,
): number[] {
  const sums = new Map<number, { sum: number; n: number }>();
  for (const r of rows) {
    const k = Math.floor(r.tsMs / (bucketS * 1000));
    const b = sums.get(k) ?? { sum: 0, n: 0 };
    b.sum += r.flowRate;
    b.n += 1;
    sums.set(k, b);
  }
  return [...sums.values()].map((b) => b.sum / b.n);
}

function percentile(sorted: readonly number[], p: number): number {
  const idx = (sorted.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  return sorted[lo]! + (sorted[hi]! - sorted[lo]!) * (idx - lo);
}

export function flowStats(values: readonly number[]): FlowStats | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return {
    samples: values.length,
    mean: values.reduce((a, b) => a + b, 0) / values.length,
    p10: percentile(sorted, 0.1),
    p50: percentile(sorted, 0.5),
  };
}

export const enoughData = (s: FlowStats | null): s is FlowStats =>
  s !== null && s.samples >= CALIBRATE_MIN_SAMPLES && s.mean >= CALIBRATE_MIN_MEAN;

export function validCutoffs(c: Cutoffs, mean: number): boolean {
  const { lowFlowCutoff: low, normalFlowCutoff: normal } = c;
  return (
    Number.isFinite(low) &&
    Number.isFinite(normal) &&
    low >= CALIBRATE_LOW_MIN &&
    low < normal &&
    normal >= CALIBRATE_NORMAL_MIN &&
    normal <= CALIBRATE_NORMAL_MAX_OF_MEAN * mean
  );
}

/** The weekly cutoffs: a fixed formula, always valid when mean >= CALIBRATE_MIN_MEAN. */
export function fallbackCutoffs(mean: number): Cutoffs {
  return {
    lowFlowCutoff: round2(Math.max(CALIBRATE_LOW_MIN, CALIBRATE_FALLBACK_LOW_OF_MEAN * mean)),
    normalFlowCutoff: round2(
      Math.max(CALIBRATE_NORMAL_MIN, CALIBRATE_FALLBACK_NORMAL_OF_MEAN * mean),
    ),
  };
}

const round2 = (x: number) => Math.round(x * 100) / 100;
