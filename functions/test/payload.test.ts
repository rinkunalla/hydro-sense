import { describe, expect, it } from "vitest";
import { normalizeDeviceId, parseIngestPayload, parseRegisterBody } from "../src/lib/payload";

const valid = {
  flowStatus: "Normal Flow",
  flowRate: 4.2,
  pulseHz: 31.5, // firmware 0.2.0 still sends it; the server ignores it
  batteryVoltage: 7.92,
  batteryFault: false,
  lat: 16.04,
  lng: 120.33,
  gpsValid: true,
  rssi: -61,
  firmware: "1.0.0",
  resetReason: null,
  trigger: "heartbeat",
};

const parse = (over: Record<string, unknown>) => parseIngestPayload({ ...valid, ...over });

describe("parseIngestPayload", () => {
  it("accepts the protocol example", () => {
    const r = parseIngestPayload(valid);
    expect(r.ok).toBe(true);
    if (r.ok)
      expect(r.value).toMatchObject({ flowStatus: "Normal Flow", flowRate: 4.2, lat: 16.04 });
  });

  it("rejects bad types, NaN, negatives and unknown enums", () => {
    expect(parse({ flowStatus: "Fast" }).ok).toBe(false);
    expect(parse({ trigger: "speed_change" }).ok).toBe(false);
    expect(parse({ flowRate: "4" }).ok).toBe(false);
    expect(parse({ flowRate: Number.NaN }).ok).toBe(false);
    expect(parse({ flowRate: -1 }).ok).toBe(false);
    expect(parse({ batteryVoltage: 99 }).ok).toBe(false);
    expect(parse({ batteryVoltage: undefined }).ok).toBe(false);
    expect(parseIngestPayload(null).ok).toBe(false);
    expect(parseIngestPayload([1]).ok).toBe(false);
  });

  it("clamps flow rate and rssi", () => {
    const r = parse({ flowRate: 500, rssi: 20 });
    expect(r.ok && r.value.flowRate).toBe(40);
    expect(r.ok && r.value.rssi).toBe(0);
  });

  it("accepts any pulseHz from old firmware, even invalid, and does not keep it", () => {
    for (const pulseHz of [75, -3, "fast", null, 1e9]) {
      const r = parse({ pulseHz });
      expect(r.ok).toBe(true);
      if (r.ok) expect(r.value).not.toHaveProperty("pulseHz");
    }
  });

  it("ignores voltage when batteryFault is true", () => {
    const r = parse({ batteryFault: true, batteryVoltage: undefined });
    expect(r.ok && r.value.batteryVoltage).toBeNull();
  });

  it("drops lat/lng when gpsValid is false, and validates them when true", () => {
    const r = parse({ gpsValid: false, lat: undefined, lng: undefined });
    expect(r.ok && r.value.lat).toBeNull();
    expect(parse({ lat: 91 }).ok).toBe(false);
  });

  it("treats lowVoltageSleep as optional", () => {
    expect(
      parse({}).ok && (parse({}) as { value: { lowVoltageSleep: boolean } }).value.lowVoltageSleep,
    ).toBe(false);
    const r = parse({ lowVoltageSleep: true });
    expect(r.ok && r.value.lowVoltageSleep).toBe(true);
  });

  it("limits string lengths", () => {
    expect(parse({ firmware: "x".repeat(33) }).ok).toBe(false);
    expect(parse({ resetReason: "x".repeat(65) }).ok).toBe(false);
  });
});

describe("parseRegisterBody and normalizeDeviceId", () => {
  it("requires a canonical device ID", () => {
    expect(parseRegisterBody({ deviceId: "A1B2C3D4E5F6", firmware: "1.0.0" }).ok).toBe(true);
    expect(parseRegisterBody({ deviceId: "a1b2c3d4e5f6" }).ok).toBe(false);
    expect(parseRegisterBody({ deviceId: "A1B2C3" }).ok).toBe(false);
  });

  it("normalizes admin input", () => {
    expect(normalizeDeviceId("a1:b2:c3:d4:e5:f6")).toBe("A1B2C3D4E5F6");
    expect(normalizeDeviceId(" A1-B2-C3-D4-E5-F6 ")).toBe("A1B2C3D4E5F6");
    expect(normalizeDeviceId("A1B2C3D4E5")).toBeNull();
    expect(normalizeDeviceId(42)).toBeNull();
  });
});
