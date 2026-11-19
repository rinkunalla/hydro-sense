import { describe, expect, it } from "vitest";
import { appendVoltage, batteryPercent, chargingTrend, smoothedVoltage } from "../src/lib/battery";
import { generateToken, safeEqual, sha256Hex } from "../src/lib/tokens";

// The device's real readings on 2026-11-17: steady about 8.05 V with dips
// (7.78, 7.63, 7.96) while it was running on battery, not charging.
const REAL = [
  8.08, 8.05, 8.07, 8.06, 8.06, 8.06, 8.06, 8.05, 8.05, 8.05, 8.04, 8.05, 8.05, 8.04, 8.06,
  7.78, 7.63, 7.96, 8.06, 8.04,
];

describe("smoothedVoltage (median, D56)", () => {
  it("ignores a dip, so the percent does not jump", () => {
    expect(smoothedVoltage([8.05, 8.06, 7.63, 8.05, 8.04])).toBe(8.05);
    expect(smoothedVoltage([8.2])).toBe(8.2);
    // Every window of the real readings gives the same few percent.
    const pcts = new Set<number>();
    for (let i = 9; i <= REAL.length; i++) pcts.add(batteryPercent(smoothedVoltage(REAL.slice(0, i))));
    expect(Math.max(...pcts) - Math.min(...pcts)).toBeLessThanOrEqual(1);
  });
});

describe("batteryPercent", () => {
  it("maps 2S 6.6 V to 0 % and 8.4 V to 100 %, clamped", () => {
    expect(batteryPercent(6.6)).toBe(0);
    expect(batteryPercent(8.4)).toBe(100);
    expect(batteryPercent(7.5)).toBe(50);
    expect(batteryPercent(5)).toBe(0);
    expect(batteryPercent(9)).toBe(100);
  });

  it("supports one cell", () => {
    expect(batteryPercent(3.75, 1)).toBe(50);
  });
});

describe("chargingTrend", () => {
  const ramp = (start: number, step: number, n = 30) =>
    Array.from({ length: n }, (_, i) => start + i * step);

  it("detects charging, discharging, full and steady", () => {
    expect(chargingTrend(ramp(7.5, 0.01))).toBe("Charging"); // +0.15 between medians
    expect(chargingTrend(ramp(7.9, -0.01))).toBe("Discharging");
    expect(chargingTrend(ramp(8.35, 0))).toBe("Full");
    expect(chargingTrend(ramp(7.6, 0))).toBe("Steady");
    expect(chargingTrend([7.6])).toBe("Steady");
  });

  it("does not call dips leaving the window charging (D56)", () => {
    expect(chargingTrend(REAL)).toBe("Steady");
    expect(chargingTrend([...REAL, 8.05, 8.06, 8.05, 8.04, 8.06])).toBe("Steady");
  });

  it("keeps recentVoltages capped at 60 (30 min)", () => {
    const list = appendVoltage(ramp(7, 0.01, 60), 8);
    expect(list).toHaveLength(60);
    expect(list.at(-1)).toBe(8);
  });
});

describe("tokens", () => {
  it("generates unique URL-safe tokens and compares hashes safely", () => {
    const a = generateToken();
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(generateToken()).not.toBe(a);
    expect(safeEqual(sha256Hex(a), sha256Hex(a))).toBe(true);
    expect(safeEqual(sha256Hex(a), sha256Hex("x"))).toBe(false);
  });
});
