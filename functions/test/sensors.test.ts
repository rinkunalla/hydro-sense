import { describe, expect, it } from "vitest";
import { SMS_TYPES, itemsFor } from "../src/alerts/alertPass";
import type { AlertItem, AlertType } from "../src/lib/messages";
import { isSensorType, sensorOf, sensorReply, starterCutoffs } from "../src/lib/sensors";

describe("sensors (D69)", () => {
  it("the reply carries each sensor's pulse factor and window", () => {
    expect(sensorReply("yf_s201")).toEqual({ pulsesPerLpm: 7.5, flowWindowS: 5 });
    expect(sensorReply("zj_dn50")).toEqual({ pulsesPerLpm: 0.2, flowWindowS: 15 });
  });

  it("unknown or missing types are the YF-S201 (devices made before v3)", () => {
    expect(sensorOf(undefined)).toBe("yf_s201");
    expect(sensorOf("zj_dn50")).toBe("zj_dn50");
    expect(isSensorType("toString")).toBe(false);
    expect(starterCutoffs("zj_dn50").lowFlowCutoff).toBeLessThan(
      starterCutoffs("zj_dn50").normalFlowCutoff,
    );
  });
});

describe("alert channels (D65)", () => {
  const item = (type: AlertType): AlertItem => ({
    deviceId: "D",
    nickname: "Main",
    type,
    reminder: false,
    batteryPercent: 10,
    batteryEmpty: false,
    sinceMs: 0,
  });
  const all = (["flow_none", "flow_low", "offline", "battery_low"] as const).map(item);

  it("SMS carries every alert but low battery; push and email carry all", () => {
    expect(itemsFor("sms", all).map((i) => i.type)).toEqual(["flow_none", "flow_low", "offline"]);
    expect(itemsFor("push", all)).toHaveLength(4);
    expect(itemsFor("email", all)).toHaveLength(4);
    expect(SMS_TYPES.has("battery_low")).toBe(false);
  });
});
