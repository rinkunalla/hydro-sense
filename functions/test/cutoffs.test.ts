import { describe, expect, it } from "vitest";
import { effectiveCutoffs } from "../src/lib/cutoffs";

const of = (d: Record<string, unknown>) => effectiveCutoffs((f) => d[f]);

describe("effective cutoffs (D43)", () => {
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
});
