import { describe, expect, it } from "vitest";
import { FLOW_RATE_MAX, SENSORS } from "../src/config";
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

  it("needs 36 samples and a mean of at least 1.25 (YF-S201)", () => {
    expect(enoughData(flowStats(Array(35).fill(5)), "yf_s201")).toBe(false);
    expect(enoughData(flowStats(Array(36).fill(5)), "yf_s201")).toBe(true);
    expect(enoughData(flowStats(Array(40).fill(1.2)), "yf_s201")).toBe(false);
    expect(enoughData(null, "yf_s201")).toBe(false);
  });

  it("a ZJ-DN50 needs a usual flow of at least 12.5 L/min", () => {
    expect(enoughData(flowStats(Array(40).fill(5)), "zj_dn50")).toBe(false);
    expect(enoughData(flowStats(Array(40).fill(12.5)), "zj_dn50")).toBe(true);
    // Never under the rotor's floor: 5 L/min No Flow line, 10 L/min Normal line.
    expect(fallbackCutoffs(12.5, "zj_dn50")).toEqual({ lowFlowCutoff: 5, normalFlowCutoff: 10 });
    expect(fallbackCutoffs(60, "zj_dn50")).toEqual({ lowFlowCutoff: 9, normalFlowCutoff: 30 });
    expect(validCutoffs({ lowFlowCutoff: 4, normalFlowCutoff: 20 }, 60, "zj_dn50")).toBe(false);
    expect(validCutoffs({ lowFlowCutoff: 5, normalFlowCutoff: 9 }, 60, "zj_dn50")).toBe(false);
  });

  it("validates cutoffs against the rules", () => {
    expect(validCutoffs({ lowFlowCutoff: 0.5, normalFlowCutoff: 4 }, 10, "yf_s201")).toBe(true);
    expect(validCutoffs({ lowFlowCutoff: 0.1, normalFlowCutoff: 4 }, 10, "yf_s201")).toBe(false);
    expect(validCutoffs({ lowFlowCutoff: 4, normalFlowCutoff: 4 }, 10, "yf_s201")).toBe(false);
    expect(validCutoffs({ lowFlowCutoff: 0.5, normalFlowCutoff: 0.9 }, 10, "yf_s201")).toBe(false);
    expect(validCutoffs({ lowFlowCutoff: 0.5, normalFlowCutoff: 8.1 }, 10, "yf_s201")).toBe(false);
  });

  it.each(["yf_s201", "zj_dn50"] as const)(
    "the weekly formula is always valid from the %s minimum mean upward",
    (sensor) => {
      for (let mean = SENSORS[sensor].calibrateMinMean; mean <= FLOW_RATE_MAX; mean += 0.05) {
        expect(validCutoffs(fallbackCutoffs(mean, sensor), mean, sensor)).toBe(true);
      }
    },
  );
});
