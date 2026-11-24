import { describe, expect, it } from "vitest";
import { effectiveCutoffs } from "../src/lib/cutoffs";

const of = (d: Record<string, unknown>) => effectiveCutoffs((f) => d[f]);

describe("effective cutoffs", () => {
  it("uses the automatic values when the owner set none", () => {
    expect(of({ lowFlowCutoff: 1.5, normalFlowCutoff: 5 })).toEqual({
      lowFlowCutoff: 1.5,
      normalFlowCutoff: 5,
    });
    expect(of({})).toEqual({ lowFlowCutoff: 0.2, normalFlowCutoff: 2 });
  });

  it("the owner's limit wins, with No Flow back at the starter line", () => {
    // Automatic low 1.5 would sit above an owner limit of 1.2 otherwise.
    expect(of({ lowFlowCutoff: 1.5, normalFlowCutoff: 5, userNormalCutoff: 1.2 })).toEqual({
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 1.2,
    });
  });

  it("ignores an out-of-range or broken value and a crossed pair", () => {
    expect(of({ normalFlowCutoff: 5, lowFlowCutoff: 1, userNormalCutoff: 0.5 })).toEqual({
      lowFlowCutoff: 1,
      normalFlowCutoff: 5,
    });
    expect(of({ userNormalCutoff: "6" })).toEqual({ lowFlowCutoff: 0.2, normalFlowCutoff: 2 });
    expect(of({ lowFlowCutoff: 3, normalFlowCutoff: 2 })).toEqual({
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2,
    });
  });

  it("a ZJ-DN50 starts from its own limits and accepts its own range", () => {
    expect(of({ sensorType: "zj_dn50" })).toEqual({ lowFlowCutoff: 5, normalFlowCutoff: 20 });
    expect(of({ sensorType: "zj_dn50", userNormalCutoff: 40 })).toEqual({
      lowFlowCutoff: 5,
      normalFlowCutoff: 40,
    });
    // 2 L/min is a fine YF-S201 limit but below what a DN50 can read.
    expect(of({ sensorType: "zj_dn50", userNormalCutoff: 2 })).toEqual({
      lowFlowCutoff: 5,
      normalFlowCutoff: 20,
    });
    // An unknown type falls back to the YF-S201.
    expect(of({ sensorType: "pump" })).toEqual({ lowFlowCutoff: 0.2, normalFlowCutoff: 2 });
  });
});
