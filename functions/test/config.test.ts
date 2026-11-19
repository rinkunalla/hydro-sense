import { describe, expect, it } from "vitest";
import * as c from "../src/config";

describe("config invariants", () => {
  it("deploys to the Firestore database region", () => {
    expect(c.REGION).toBe("asia-east1");
  });

  it("alerts offline no sooner than the device counts as Offline", () => {
    // Firmware 0.3.0 is Offline after two missed heartbeats; the alert
    // also needs online == false, so 0.2.0 devices (180 s) alert at the flip.
    expect(c.OFFLINE_ALERT_AFTER_S).toBeGreaterThanOrEqual(
      Math.max(c.OFFLINE_AFTER_MIN_S, c.OFFLINE_MISSED_HEARTBEATS * c.DEVICE_HEARTBEAT_S),
    );
  });

  it("re-arms low battery above the alert level", () => {
    expect(c.BATTERY_REARM_PERCENT).toBeGreaterThan(c.LOW_BATTERY_PERCENT);
  });

  it("refreshes devices.updatedAt within the throttle window", () => {
    expect(c.DEVICES_WRITE_MIN_INTERVAL_S).toBeLessThan(c.DEVICES_WRITE_MAX_AGE_S);
  });

  it("keeps the calibration fallback valid at the minimum mean", () => {
    const mean = c.CALIBRATE_MIN_MEAN;
    const normal = Math.max(c.CALIBRATE_NORMAL_MIN, c.CALIBRATE_FALLBACK_NORMAL_OF_MEAN * mean);
    const low = Math.max(c.CALIBRATE_LOW_MIN, c.CALIBRATE_FALLBACK_LOW_OF_MEAN * mean);
    expect(low).toBeGreaterThanOrEqual(c.CALIBRATE_LOW_MIN);
    expect(low).toBeLessThan(normal);
    expect(normal).toBeGreaterThanOrEqual(c.CALIBRATE_NORMAL_MIN);
    expect(normal).toBeLessThanOrEqual(c.CALIBRATE_NORMAL_MAX_OF_MEAN * mean);
  });

  it("starter cutoffs are ordered", () => {
    expect(c.STARTER_LOW_FLOW_CUTOFF).toBeLessThan(c.STARTER_NORMAL_FLOW_CUTOFF);
  });

  it("accepts only 12 uppercase hex device IDs", () => {
    expect(c.DEVICE_ID_PATTERN.test("A1B2C3D4E5F6")).toBe(true);
    expect(c.DEVICE_ID_PATTERN.test("a1b2c3d4e5f6")).toBe(false);
    expect(c.DEVICE_ID_PATTERN.test("A1:B2:C3:D4:E5:F6")).toBe(false);
  });
});
