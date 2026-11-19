import { describe, expect, it } from "vitest";
import {
  EMPTY_STATE,
  batteryCondition,
  decide,
  flowCondition,
  offlineCondition,
  type AlertState,
  type Condition,
  type DeviceView,
} from "../src/lib/alertLogic";

const S = 1000;
const MIN = 60 * S;
const H = 60 * MIN;
const T = 1_800_000_000_000;

const view = (over: Partial<DeviceView>): DeviceView => ({
  online: true,
  lastSeenMs: T,
  flowStatus: "Normal Flow",
  abnormalSinceMs: null,
  batteryPercent: 80,
  batteryFault: false,
  ...over,
});

const fault = (type: "flow_low" | "flow_none" | "battery_low" | "offline"): Condition => ({
  kind: "fault",
  type,
});
const recovered: Condition = { kind: "recovered" };

/** Runs a sequence of [time, condition] through decide(); returns what was sent. */
function run(steps: [number, Condition][], start: AlertState = EMPTY_STATE) {
  let state = start;
  const sent: string[] = [];
  for (const [t, cond] of steps) {
    const d = decide(state, cond, t);
    if (d.send) sent.push(`${d.send.reminder ? "reminder:" : ""}${d.send.type}`);
    state = d.next;
  }
  return { sent, state };
}

describe("conditions", () => {
  it("flow needs 30 continuous seconds and an online device (D62)", () => {
    expect(
      flowCondition(view({ flowStatus: "No Flow", abnormalSinceMs: T - 29 * S }), T).kind,
    ).toBe("neutral");
    expect(flowCondition(view({ flowStatus: "No Flow", abnormalSinceMs: T - 30 * S }), T)).toEqual(
      fault("flow_none"),
    );
    expect(flowCondition(view({ flowStatus: "Low Flow", abnormalSinceMs: T - 30 * S }), T)).toEqual(
      fault("flow_low"),
    );
    expect(
      flowCondition(view({ online: false, flowStatus: "No Flow", abnormalSinceMs: T - H }), T).kind,
    ).toBe("skip");
  });

  it("battery alerts below 20 % and re-arms only above 30 %", () => {
    expect(batteryCondition(view({ batteryPercent: 19 }))).toEqual(fault("battery_low"));
    expect(batteryCondition(view({ batteryPercent: 25 })).kind).toBe("neutral");
    expect(batteryCondition(view({ batteryPercent: 31 })).kind).toBe("recovered");
    expect(batteryCondition(view({ batteryPercent: null, batteryFault: true })).kind).toBe(
      "neutral",
    );
  });

  it("offline alerts after 40 s of silence (D58, D62)", () => {
    expect(offlineCondition(view({ online: false, lastSeenMs: T - 39_000 }), T).kind).toBe(
      "neutral",
    );
    expect(offlineCondition(view({ online: false, lastSeenMs: T - 40_000 }), T)).toEqual(
      fault("offline"),
    );
    expect(offlineCondition(view({ online: false, lastSeenMs: null }), T).kind).toBe("neutral");
    expect(offlineCondition(view({}), T).kind).toBe("recovered");
  });
});

describe("decide", () => {
  it("sends once, locks 6 h, sends two reminders, then stays silent", () => {
    const f = fault("flow_none");
    const { sent } = run([
      [T, f],
      [T + 1 * H, f],
      [T + 6 * H, f],
      [T + 7 * H, f],
      [T + 12 * H, f],
      [T + 18 * H, f],
      [T + 48 * H, f],
    ]);
    expect(sent).toEqual(["flow_none", "reminder:flow_none", "reminder:flow_none"]);
  });

  it("needs 10 continuous minutes of recovery before it can alert again", () => {
    const f = fault("flow_low");
    const neutral: Condition = { kind: "neutral" };
    const { sent, state } = run([
      [T, f],
      [T + 1 * MIN, recovered],
      [T + 9 * MIN, recovered],
      [T + 9.5 * MIN, neutral], // flapped back to Low inside 10 min
      [T + 10.5 * MIN, f],
      [T + 11 * MIN, recovered],
      [T + 21 * MIN, recovered], // 10 min of Normal: re-armed
      [T + 30 * MIN, f],
    ]);
    expect(sent).toEqual(["flow_low", "flow_low"]);
    expect(state.active).toBe(true);
  });

  it("escalates Low -> No once, and No -> Low sends nothing", () => {
    const { sent } = run([
      [T, fault("flow_low")],
      [T + MIN, fault("flow_none")],
      [T + 2 * MIN, fault("flow_low")],
      [T + 3 * MIN, fault("flow_none")],
    ]);
    expect(sent).toEqual(["flow_low", "flow_none"]);
  });

  it("skip leaves the state untouched", () => {
    const start = run([[T, fault("battery_low")]]).state;
    expect(decide(start, { kind: "skip" }, T + 100 * H).next).toBe(start);
  });
});
