import { describe, expect, it } from "vitest";
import {
  bucketAverages,
  enoughData,
  fallbackCutoffs,
  flowStats,
  validCutoffs,
} from "../src/lib/calibrationMath";

describe("calibration math", () => {
  it("averages per 5-minute bucket so bursts do not dominate", () => {
    const rows = [
      { tsMs: 0, flowRate: 10 },
      { tsMs: 1000, flowRate: 2 },
      { tsMs: 2000, flowRate: 2 },
      { tsMs: 300_000, flowRate: 8 },
    ];
    expect(bucketAverages(rows, 300).sort()).toEqual([14 / 3, 8].sort());
  });

  it("computes mean, p10 and p50", () => {
    const s = flowStats([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])!;
    expect(s.mean).toBe(5.5);
    expect(s.p50).toBe(5.5);
    expect(s.p10).toBeCloseTo(1.9);
  });

  it("needs 36 samples and a mean of at least 1.25", () => {
    expect(enoughData(flowStats(Array(35).fill(5)))).toBe(false);
    expect(enoughData(flowStats(Array(36).fill(5)))).toBe(true);
    expect(enoughData(flowStats(Array(40).fill(1.2)))).toBe(false);
    expect(enoughData(null)).toBe(false);
  });

  it("validates cutoffs against the rules", () => {
    expect(validCutoffs({ lowFlowCutoff: 0.5, normalFlowCutoff: 4 }, 10)).toBe(true);
    expect(validCutoffs({ lowFlowCutoff: 0.1, normalFlowCutoff: 4 }, 10)).toBe(false);
    expect(validCutoffs({ lowFlowCutoff: 4, normalFlowCutoff: 4 }, 10)).toBe(false);
    expect(validCutoffs({ lowFlowCutoff: 0.5, normalFlowCutoff: 0.9 }, 10)).toBe(false);
    expect(validCutoffs({ lowFlowCutoff: 0.5, normalFlowCutoff: 8.1 }, 10)).toBe(false);
  });

  it("the weekly formula always gives 0.2 <= low < normal from the minimum mean upward", () => {
    for (let mean = 1.25; mean <= 40; mean += 0.05) {
      expect(validCutoffs(fallbackCutoffs(mean), mean)).toBe(true);
    }
  });
});
