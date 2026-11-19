import { manilaSlot } from "../src/lib/time";
import { describe, expect, it } from "vitest";
import {
  isStale,
  offlineAfterS,
  nextAbnormalSince,
  rateChangedEnough,
  sampleDue,
  shouldWriteDevices,
} from "../src/lib/decisions";

const S = 1000;
const NOW = 1_800_000_000_000;

describe("nextAbnormalSince", () => {
  it("sets on Normal -> Low and keeps through Low -> No", () => {
    const t1 = nextAbnormalSince("Normal Flow", null, "Low Flow", NOW);
    expect(t1).toBe(NOW);
    expect(nextAbnormalSince("Low Flow", t1, "No Flow", NOW + 30 * S)).toBe(NOW);
    expect(nextAbnormalSince("No Flow", t1, "Low Flow", NOW + 60 * S)).toBe(NOW);
  });

  it("clears on Normal and sets on a first abnormal reading", () => {
    expect(nextAbnormalSince("No Flow", NOW, "Normal Flow", NOW + S)).toBeNull();
    expect(nextAbnormalSince(null, null, "No Flow", NOW)).toBe(NOW);
  });
});

describe("rateChangedEnough", () => {
  it("needs both 15 % and 0.3 L/min", () => {
    expect(rateChangedEnough(10, 12)).toBe(true); // 20 %, 2.0
    expect(rateChangedEnough(10, 11)).toBe(false); // 10 %
    expect(rateChangedEnough(0.5, 0.7)).toBe(false); // 40 % but 0.2 L/min
    expect(rateChangedEnough(0, 0.25)).toBe(false); // noise at zero
    expect(rateChangedEnough(0, 0.3)).toBe(true);
    expect(rateChangedEnough(null, 1)).toBe(true);
  });
});

describe("manilaSlot (History graph)", () => {
  it("is the 15-minute slot of the Manila day", () => {
    // 2026-11-16 00:00 Manila = 2026-11-15 16:00 UTC
    const midnight = Date.UTC(2026, 10, 15, 16, 0);
    expect(manilaSlot(midnight)).toBe(0);
    expect(manilaSlot(midnight + 14 * 60_000)).toBe(0);
    expect(manilaSlot(midnight + 15 * 60_000)).toBe(1);
    expect(manilaSlot(midnight + 23 * 3_600_000 + 59 * 60_000)).toBe(95);
  });
});

describe("shouldWriteDevices", () => {
  const base = {
    statusChanged: false,
    locationChanged: false,
    prevRate: 10,
    nextRate: 10,
    updatedAtMs: NOW - 60 * S,
    nowMs: NOW,
  };

  it("skips a steady heartbeat", () => {
    expect(shouldWriteDevices(base)).toBe(false);
  });

  it("writes on a status change or location change at any age", () => {
    expect(shouldWriteDevices({ ...base, statusChanged: true, updatedAtMs: NOW - S })).toBe(true);
    expect(shouldWriteDevices({ ...base, locationChanged: true, updatedAtMs: NOW - S })).toBe(true);
  });

  it("writes a 20 % rate change only after 30 s", () => {
    expect(shouldWriteDevices({ ...base, nextRate: 12, updatedAtMs: NOW - 9 * S })).toBe(false);
    expect(shouldWriteDevices({ ...base, nextRate: 12, updatedAtMs: NOW - 10 * S })).toBe(true);
  });

  it("refreshes updatedAt after 5 min even when steady", () => {
    expect(shouldWriteDevices({ ...base, updatedAtMs: NOW - 299 * S })).toBe(false);
    expect(shouldWriteDevices({ ...base, updatedAtMs: NOW - 300 * S })).toBe(true);
  });
});

describe("sampleDue and isStale", () => {
  it("samples once per interval", () => {
    expect(sampleDue(null, NOW, 300)).toBe(true);
    expect(sampleDue(NOW - 299 * S, NOW, 300)).toBe(false);
    expect(sampleDue(NOW - 300 * S, NOW, 300)).toBe(true);
  });

  it("flags silence of 3 min, never a device that has not reported", () => {
    expect(isStale(NOW - 179 * S, NOW)).toBe(false);
    expect(isStale(NOW - 180 * S, NOW)).toBe(true);
    expect(isStale(null, NOW)).toBe(false);
  });

  it("uses two missed heartbeats when the device reports its heartbeat", () => {
    expect(offlineAfterS(30)).toBe(60);
    expect(offlineAfterS(10)).toBe(40);
    expect(offlineAfterS(null)).toBe(180);
    expect(isStale(NOW - 59 * S, NOW, 30)).toBe(false);
    expect(isStale(NOW - 60 * S, NOW, 30)).toBe(true);
  });
});
