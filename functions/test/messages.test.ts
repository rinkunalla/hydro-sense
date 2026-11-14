import { describe, expect, it } from "vitest";
import { DIGEST_SMS, buildEmail, buildSms, byDevice, type AlertItem } from "../src/lib/messages";

const T = Date.UTC(2026, 10, 2, 7, 12); // Nov 2, 3:12 PM in Asia/Manila

const item = (over: Partial<AlertItem>): AlertItem => ({
  deviceId: "D1",
  nickname: "Garden Line",
  type: "flow_none",
  reminder: false,
  batteryPercent: null,
  batteryEmpty: false,
  sinceMs: T,
  ...over,
});

describe("single SMS uses the spec wording exactly", () => {
  it.each([
    ["flow_low", "Hydro Sense: Garden Line has low water flow. Please check the pipe or valve."],
    [
      "flow_none",
      "Hydro Sense: No water is flowing at Garden Line. Please check the pipe, valve or pump.",
    ],
    ["offline", "Hydro Sense: Garden Line is offline. Please check its power and Wi-Fi."],
  ] as const)("%s", (type, text) => {
    expect(buildSms([item({ type })])).toBe(text);
  });

  it("battery, low-voltage sleep and reminders", () => {
    expect(buildSms([item({ type: "battery_low", batteryPercent: 15 })])).toBe(
      "Hydro Sense: Garden Line battery is low (15%). Please check its solar panel.",
    );
    expect(buildSms([item({ type: "offline", batteryEmpty: true })])).toBe(
      "Hydro Sense: Garden Line is offline because its battery is empty. Please check its solar panel.",
    );
    expect(buildSms([item({ type: "flow_none", reminder: true })])).toBe(
      "Hydro Sense: Reminder: still no water at Garden Line. Please check the pipe, valve or pump.",
    );
    expect(buildSms([item({ type: "flow_low", reminder: true })])).toBe(
      "Hydro Sense: Reminder: Garden Line still has low water flow. Please check the pipe or valve.",
    );
  });

  it("every template fits in 160 characters with a 24-character nickname", () => {
    const nickname = "x".repeat(24);
    for (const type of ["flow_low", "flow_none", "battery_low", "offline"] as const) {
      for (const reminder of [false, true]) {
        const text = buildSms([item({ nickname, type, reminder, batteryPercent: 100 })]);
        expect(text.length).toBeLessThanOrEqual(160);
      }
    }
    expect(DIGEST_SMS.length).toBeLessThanOrEqual(160);
  });
});

describe("batched SMS", () => {
  it("lists devices worst first and stays within 160 characters", () => {
    const text = buildSms([
      item({ deviceId: "A", nickname: "Orchard", type: "battery_low", batteryPercent: 12 }),
      item({ deviceId: "B", nickname: "Kitchen", type: "flow_low" }),
      item({ deviceId: "C", nickname: "Garden Line", type: "flow_none" }),
    ]);
    expect(text).toBe(
      "Hydro Sense: 3 areas need attention: Garden Line (no flow), Kitchen (low flow), Orchard (low battery). Open the app.",
    );
  });

  it("adds +k more when the names do not fit", () => {
    const items = ["A", "B", "C", "D", "E"].map((id) =>
      item({ deviceId: id, nickname: `${id}${"x".repeat(23)}`, type: "flow_low" }),
    );
    const text = buildSms(items);
    expect(text.length).toBeLessThanOrEqual(160);
    expect(text).toMatch(/^Hydro Sense: 5 areas need attention: .+, \+\d more\. Open the app\.$/);
  });

  it("counts each device once, by its worst issue", () => {
    const list = byDevice([
      item({ deviceId: "A", type: "battery_low" }),
      item({ deviceId: "A", type: "flow_none" }),
    ]);
    expect(list).toHaveLength(1);
    expect(list[0]!.type).toBe("flow_none");
  });
});

describe("email", () => {
  it("single alert subject, since-time in Manila and the what-to-check list", () => {
    const mail = buildEmail([item({})]);
    expect(mail.subject).toBe("Hydro Sense alert: Garden Line - No flow");
    expect(mail.text).toContain("No water is flowing at Garden Line. Since Nov 2, 3:12 PM.");
    expect(mail.text).toContain("What to check:");
    expect(mail.text).toContain("Open the Hydro Sense app for live status.");
    expect(mail.text).not.toMatch(/16\.0|120\.3|L\/min/);
  });

  it("batch subject and reminder prefix", () => {
    expect(
      buildEmail([item({ deviceId: "A" }), item({ deviceId: "B", nickname: "K" })]).subject,
    ).toBe("Hydro Sense alert: 2 areas need attention");
    const r = buildEmail([item({ reminder: true })]);
    expect(r.subject).toBe("Reminder: Hydro Sense alert: Garden Line - No flow");
    expect(r.text.startsWith("Reminder:")).toBe(true);
  });
});

describe("push (docs/UI_UX_SPEC.md section 7)", () => {
  it("uses the spec titles, the Still: prefix and the payload shape", async () => {
    const { buildPush } = await import("../src/lib/messages");
    const base = {
      deviceId: "D1",
      nickname: "Garden",
      reminder: false,
      batteryPercent: 14,
      batteryEmpty: false,
      sinceMs: 0,
    };
    expect(buildPush([{ ...base, type: "flow_none" }])).toEqual({
      title: "No water at Garden",
      body: "Please check the pipe, valve or pump.",
      data: { deviceId: "D1" },
    });
    expect(buildPush([{ ...base, type: "battery_low", reminder: true }]).title).toBe(
      "Still: Garden battery is low (14%)",
    );
    expect(buildPush([{ ...base, type: "offline", batteryEmpty: true }]).title).toBe(
      "Garden is offline: battery empty",
    );
    const five = ["A", "B", "C", "D", "E"].map((n, i) => ({
      ...base,
      deviceId: n,
      nickname: n,
      type: i ? ("flow_low" as const) : ("flow_none" as const),
    }));
    expect(buildPush(five)).toEqual({
      title: "5 areas need attention",
      body: "A (no flow), B (low flow), C (low flow), +2 more.",
      data: { kind: "batch" },
    });
  });
});
