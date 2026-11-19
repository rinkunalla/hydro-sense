import { describe, expect, it } from "vitest";
import { applyUpload, emptyLive, minutePeak, type Live, type State } from "../src/lib/live";
import type { IngestPayload } from "../src/lib/payload";

const NOW = 1_800_000_000_000;
const S = 1000;

const state = (o: Partial<State> = {}): State => ({
  ownerUid: "u1",
  removed: false,
  tokenHash: "h",
  lowFlowCutoff: 0.2,
  normalFlowCutoff: 2,
  recentVoltages: [],
  lastSampleAt: NOW - 60 * S,
  gpsLat: 16.04,
  gpsLng: 120.33,
  firmware: "0.3.0",
  open: {},
  ...o,
});

const live = (o: Partial<Live> = {}): Live => ({
  ...emptyLive("u1"),
  online: true,
  lastSeen: NOW - 30 * S,
  flowStatus: "Normal Flow",
  flowRate: 8,
  statusChangedAt: NOW - 3_600 * S,
  ...o,
});

const upload = (o: Partial<IngestPayload> = {}): IngestPayload => ({
  flowStatus: "Normal Flow",
  flowRate: 8,
  batteryVoltage: 8.0,
  batteryFault: false,
  lat: 16.04,
  lng: 120.33,
  gpsValid: true,
  rssi: -60,
  firmware: "0.3.0",
  resetReason: null,
  trigger: "heartbeat",
  lowVoltageSleep: false,
  heartbeatS: 30,
  ...o,
});

describe("applyUpload (D48, D49)", () => {
  it("a steady heartbeat changes only the live node: no problem, sample or GPS write", () => {
    const r = applyUpload(live(), state(), upload(), NOW);
    expect(r.problems).toEqual([]);
    expect(r.sample).toBe(false);
    expect(r.gpsMoved).toBe(false);
    expect(r.live).toMatchObject({ online: true, lastSeen: NOW, flowStatus: "Normal Flow", heartbeatS: 30 });
    expect(r.live.statusChangedAt).toBe(NOW - 3_600 * S);
  });

  it("Normal -> No Flow opens a no_flow problem and sets abnormalSince", () => {
    const r = applyUpload(live(), state(), upload({ flowStatus: "No Flow", flowRate: 0 }), NOW);
    expect(r.problems).toEqual([{ op: "open", type: "no_flow", startedAt: NOW }]);
    expect(r.live.abnormalSince).toBe(NOW);
    expect(r.live.statusChangedAt).toBe(NOW);
  });

  it("Low -> No Flow closes low_flow (a blip is dropped) and keeps abnormalSince", () => {
    const prev = live({ flowStatus: "Low Flow", abnormalSince: NOW - 600 * S });
    const r = applyUpload(prev, state({ open: { low_flow: "p1" } }), upload({ flowStatus: "No Flow" }), NOW);
    expect(r.problems).toEqual([
      { op: "close", type: "low_flow", id: "p1", endedAt: NOW, dropIfShort: true },
      { op: "open", type: "no_flow", startedAt: NOW },
    ]);
    expect(r.live.abnormalSince).toBe(NOW - 600 * S);
  });

  it("No Flow -> Normal closes the problem and clears abnormalSince", () => {
    const prev = live({ flowStatus: "No Flow", abnormalSince: NOW - 600 * S });
    const r = applyUpload(prev, state({ open: { no_flow: "p2" } }), upload(), NOW);
    expect(r.problems).toEqual([
      { op: "close", type: "no_flow", id: "p2", endedAt: NOW, dropIfShort: true },
    ]);
    expect(r.live.abnormalSince).toBeNull();
  });

  it("the first upload after Offline closes the offline problem", () => {
    const prev = live({ online: false });
    const r = applyUpload(prev, state({ open: { offline: "p3" } }), upload(), NOW);
    expect(r.problems).toEqual([
      { op: "close", type: "offline", id: "p3", endedAt: NOW, dropIfShort: false },
    ]);
    expect(r.live.online).toBe(true);
  });

  it("low battery opens below 20 % and closes only above 30 %", () => {
    const low = Array(5).fill(6.85); // about 14 %
    const r = applyUpload(live(), state({ recentVoltages: low }), upload({ batteryVoltage: 6.85 }), NOW);
    expect(r.problems).toEqual([{ op: "open", type: "battery_low", startedAt: NOW }]);

    const mid = Array(5).fill(7.05); // 25 %: still open, nothing changes
    const open = state({ recentVoltages: mid, open: { battery_low: "b1" } });
    expect(applyUpload(live(), open, upload({ batteryVoltage: 7.05 }), NOW).problems).toEqual([]);

    const high = state({ recentVoltages: Array(5).fill(7.3), open: { battery_low: "b1" } });
    expect(applyUpload(live(), high, upload({ batteryVoltage: 7.3 }), NOW).problems).toEqual([
      { op: "close", type: "battery_low", id: "b1", endedAt: NOW, dropIfShort: false },
    ]);
  });

  it("a flow sample is due every 15 min, and GPS is written only when it moves", () => {
    const due = applyUpload(live(), state({ lastSampleAt: NOW - 900 * S }), upload(), NOW);
    expect(due.sample).toBe(true);
    expect(due.state.lastSampleAt).toBe(NOW);
    const moved = applyUpload(live(), state(), upload({ lat: 16.05 }), NOW);
    expect(moved.gpsMoved).toBe(true);
    expect(moved.state.gpsLat).toBe(16.05);
  });

  it("a battery fault clears the percent and the charging trend", () => {
    const r = applyUpload(
      live({ batteryPercent: 80, chargingStatus: "Charging" }),
      state(),
      upload({ batteryVoltage: null, batteryFault: true }),
      NOW,
    );
    expect(r.live).toMatchObject({ batteryPercent: null, chargingStatus: null, batteryFault: true });
  });
});

describe("minutePeak", () => {
  it("keeps the highest reading of a minute and starts fresh on the next", () => {
    expect(minutePeak(null, null, "2026-11-17/974", 17)).toBe(17);
    expect(minutePeak("2026-11-17/974", 17, "2026-11-17/974", 2.8)).toBe(17); // the drop
    expect(minutePeak("2026-11-17/974", 17, "2026-11-17/975", 0)).toBe(0); // next minute
    expect(minutePeak("2026-11-16/974", 17, "2026-11-17/974", 1)).toBe(1); // another day
  });
});
