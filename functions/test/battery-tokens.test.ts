import { describe, expect, it } from "vitest";
import { appendVoltage, batteryPercent, chargingTrend } from "../src/lib/battery";
import { generateToken, safeEqual, sha256Hex } from "../src/lib/tokens";

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
  const ramp = (start: number, step: number, n = 10) =>
    Array.from({ length: n }, (_, i) => start + i * step);

  it("detects charging, discharging, full and steady", () => {
    expect(chargingTrend(ramp(7.5, 0.01))).toBe("Charging"); // +0.05 between means
    expect(chargingTrend(ramp(7.9, -0.01))).toBe("Discharging");
    expect(chargingTrend(ramp(8.35, 0))).toBe("Full");
    expect(chargingTrend(ramp(7.6, 0))).toBe("Steady");
    expect(chargingTrend([7.6])).toBe("Steady");
  });

  it("keeps recentVoltages capped at 20", () => {
    const list = appendVoltage(ramp(7, 0.01, 20), 8);
    expect(list).toHaveLength(20);
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
