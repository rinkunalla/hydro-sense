// Phase 3 acceptance tests (KICKOFF.md): alerts, AI summary, calibration, admin
// functions. Run in-process against the Firestore and Auth emulators with fake
// SMS, email and model providers; time is passed explicitly, never waited for.
// Run WITHOUT the Functions emulator (npm run test:emulator does this): its real
// Firestore triggers would race these in-process calls on the same database.
import { getAuth } from "firebase-admin/auth";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/https";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { collectHardwareFacts, generateReport } from "../src/admin/hardwareReport";
import { createClientAccount } from "../src/admin/clientAccount";
import { generateClientFlowSummaryOnChange, refreshSummary } from "../src/ai/summary";
import { runAlertPass } from "../src/alerts/alertPass";
import { calibrateDevice } from "../src/calibration/calibrate";
import { C, db, ts } from "../src/lib/db";
import { setProviders, type ModelRequest, type Providers } from "../src/lib/providers";
import { manilaDateKey } from "../src/lib/time";
import { runMonitorPass } from "../src/monitor/monitorDevices";

const PROJECT = process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836";
const FIRESTORE = process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080";
const AUTH = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099";

const S = 1000;
const MIN = 60 * S;
const H = 60 * MIN;
const PHONE = "639171234567";
const EMAIL = "client@example.com";

class Fake implements Providers {
  smsSent: { to: string; msg: string }[] = [];
  emailSent: { to: string; subject: string; text: string }[] = [];
  modelCalls: ModelRequest[] = [];
  smsFail = false;
  emailFail = false;
  modelFail = false;
  modelReply: (req: ModelRequest) => string = () =>
    "All areas have normal flow. No action is needed.";

  sms = {
    send: async (to: string, msg: string) => {
      // Echo the recipient like a real provider error might, to test scrubbing.
      if (this.smsFail) throw new Error(`Semaphore rejected ${to}`);
      this.smsSent.push({ to, msg });
    },
  };
  email = {
    send: async (to: string, subject: string, text: string) => {
      if (this.emailFail) throw new Error(`SMTP 550 mailbox ${to} unavailable`);
      this.emailSent.push({ to, subject, text });
    },
  };
  model = {
    generate: async (req: ModelRequest) => {
      this.modelCalls.push(req);
      if (this.modelFail) throw new Error("model timeout");
      return this.modelReply(req);
    },
  };
}

let fake: Fake;
let T0: number;

interface DeviceSeed {
  nickname?: string;
  flowStatus?: string | null;
  flowRate?: number;
  abnormalSinceMs?: number | null;
  pausedUntilMs?: number | null;
  online?: boolean;
  lastSeenMs?: number | null;
  batteryPercent?: number | null;
  lowVoltageSleep?: boolean;
}

async function seedClient() {
  await db
    .collection(C.config)
    .doc("system")
    .set({ clientUid: "client1", clientName: "C", clientEmail: EMAIL });
  await db.collection(C.users).doc("client1").set({ role: "client", phone: PHONE, email: EMAIL });
}

async function seedDevice(id: string, o: DeviceSeed = {}) {
  const t = (v: number | null | undefined) => (v === null || v === undefined ? null : ts(v));
  await db
    .collection(C.devices)
    .doc(id)
    .set({
      ownerUid: "client1",
      nickname: o.nickname ?? `Line ${id}`,
      flowStatus: o.flowStatus === undefined ? "Normal Flow" : o.flowStatus,
      flowRate: o.flowRate ?? 8,
      abnormalSince: t(o.abnormalSinceMs),
      pausedUntil: t(o.pausedUntilMs),
      lat: 16.04,
      lng: 120.33,
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2.0,
      statusChangedAt: ts(T0 - H),
      updatedAt: ts(T0),
    });
  await db
    .collection(C.deviceHealth)
    .doc(id)
    .set({
      ownerUid: "client1",
      online: o.online ?? true,
      lastSeen: t(o.lastSeenMs === undefined ? T0 : o.lastSeenMs),
      batteryPercent: o.batteryPercent === undefined ? 80 : o.batteryPercent,
      batteryVoltage: 7.9,
      batteryFault: false,
      lowVoltageSleep: o.lowVoltageSleep ?? false,
      firmware: "1.0.0",
      rssi: -60,
    });
}

const setFlow = (id: string, flowStatus: string, abnormalSinceMs: number | null) =>
  db
    .collection(C.devices)
    .doc(id)
    .update({
      flowStatus,
      abnormalSince: abnormalSinceMs === null ? null : ts(abnormalSinceMs),
    });

const allSms = () => fake.smsSent.map((s) => s.msg);

beforeEach(async () => {
  await fetch(`http://${FIRESTORE}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {
    method: "DELETE",
  });
  await fetch(`http://${AUTH}/emulator/v1/projects/${PROJECT}/accounts`, { method: "DELETE" });
  fake = new Fake();
  setProviders(fake);
  T0 = Math.floor(Date.now() / MIN) * MIN;
});

afterAll(() => setProviders(null));

describe("alerts", () => {
  it("needs 60 s of Low/No Flow, then sends one SMS and one email", async () => {
    await seedClient();
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 59 * S,
    });
    expect((await runAlertPass(T0)).sent).toHaveLength(0);

    const r = await runAlertPass(T0 + S);
    expect(r).toMatchObject({ sms: "sent", email: "sent" });
    expect(allSms()).toEqual([
      "Hydro Sense: No water is flowing at Garden Line. Please check the pipe, valve or pump.",
    ]);
    expect(fake.smsSent[0]!.to).toBe(PHONE);
    expect(fake.emailSent[0]).toMatchObject({
      to: EMAIL,
      subject: "Hydro Sense alert: Garden Line - No flow",
    });
  });

  it("locks for 6 h, sends two reminders, then stays silent", async () => {
    await seedClient();
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    for (const t of [0, 1 * H, 5 * H, 6 * H, 7 * H, 12 * H, 18 * H, 30 * H])
      await runAlertPass(T0 + t);
    expect(allSms()).toHaveLength(3);
    expect(allSms()[1]).toContain("Reminder: still no water at Garden Line");
  });

  it("does not set the lock when both channels fail; SMS failure does not block email", async () => {
    await seedClient();
    await seedDevice("D1", { flowStatus: "Low Flow", abnormalSinceMs: T0 - 2 * MIN });
    fake.smsFail = true;
    fake.emailFail = true;
    expect((await runAlertPass(T0)).sent).toHaveLength(0);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(false);

    fake.emailFail = false;
    const r = await runAlertPass(T0 + MIN);
    expect(r).toMatchObject({ sms: "failed", email: "sent" });
    expect(fake.emailSent).toHaveLength(1);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(true);
  });

  it("re-arms only after 10 min of Normal; a Low/Normal flap sends nothing", async () => {
    await seedClient();
    await seedDevice("D1", { flowStatus: "Low Flow", abnormalSinceMs: T0 - 2 * MIN });
    await runAlertPass(T0);
    await setFlow("D1", "Normal Flow", null);
    await runAlertPass(T0 + 1 * MIN);
    await runAlertPass(T0 + 8 * MIN);
    await setFlow("D1", "Low Flow", T0 + 8.5 * MIN); // flap inside 10 min
    await runAlertPass(T0 + 10 * MIN);
    expect(allSms()).toHaveLength(1);

    await setFlow("D1", "Normal Flow", null);
    await runAlertPass(T0 + 11 * MIN);
    await runAlertPass(T0 + 22 * MIN); // 11 min of Normal: re-armed
    await setFlow("D1", "Low Flow", T0 + 23 * MIN);
    await runAlertPass(T0 + 25 * MIN);
    expect(allSms()).toHaveLength(2);
  });

  it("escalates Low -> No once; No -> Low sends nothing", async () => {
    await seedClient();
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "Low Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    await runAlertPass(T0);
    await setFlow("D1", "No Flow", T0 - 2 * MIN);
    await runAlertPass(T0 + MIN);
    await setFlow("D1", "Low Flow", T0 - 2 * MIN);
    await runAlertPass(T0 + 2 * MIN);
    await setFlow("D1", "No Flow", T0 - 2 * MIN);
    await runAlertPass(T0 + 3 * MIN);
    expect(allSms()).toEqual([
      "Hydro Sense: Garden Line has low water flow. Please check the pipe or valve.",
      "Hydro Sense: No water is flowing at Garden Line. Please check the pipe, valve or pump.",
    ]);
  });

  it("batches 3 failing devices into one SMS and one email within 160 characters", async () => {
    await seedClient();
    for (const id of ["D1", "D2", "D3"]) {
      await seedDevice(id, {
        nickname: `${id} ${"x".repeat(21)}`,
        flowStatus: "No Flow",
        abnormalSinceMs: T0 - 2 * MIN,
      });
    }
    const r = await runAlertPass(T0);
    expect(r.sent).toHaveLength(3);
    expect(fake.smsSent).toHaveLength(1);
    expect(fake.emailSent).toHaveLength(1);
    // Three 24-character names fit exactly (158 chars); "+k more" is unit-tested.
    expect(allSms()[0]!.length).toBeLessThanOrEqual(160);
    expect(allSms()[0]).toMatch(
      /^Hydro Sense: 3 areas need attention: D1 x+ \(no flow\), D2 .+, D3 .+\. Open the app\.$/,
    );
    expect(fake.emailSent[0]!.subject).toBe("Hydro Sense alert: 3 areas need attention");
  });

  it("caps each channel at 10 per day, then sends one digest", async () => {
    await seedClient();
    await db.collection(C.alertDaily).doc(manilaDateKey(T0)).set({ smsCount: 10, emailCount: 3 });
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r1 = await runAlertPass(T0);
    expect(r1).toMatchObject({ sms: "digest", email: "sent" });
    expect(allSms()).toEqual(["Hydro Sense: More alerts today. Open the app for live status."]);

    await seedDevice("D2", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r2 = await runAlertPass(T0 + MIN);
    expect(r2).toMatchObject({ sms: "capped", email: "sent" });
    expect(fake.smsSent).toHaveLength(1);
    const cap = await db.collection(C.errorLogs).where("code", "==", "ALERT_CAP_REACHED").get();
    expect(cap.size).toBe(1);
  });

  it("shows Offline at 3 min but sends the offline alert only after 15 min", async () => {
    await seedClient();
    await seedDevice("D1", { nickname: "Garden Line", online: true, lastSeenMs: T0 - 4 * MIN });
    const m = await runMonitorPass(T0);
    expect(m.flipped).toEqual(["D1"]);
    expect(fake.smsSent).toHaveLength(0);

    await runAlertPass(T0 + 10 * MIN);
    expect(fake.smsSent).toHaveLength(0);
    await runAlertPass(T0 + 11 * MIN);
    expect(allSms()).toEqual([
      "Hydro Sense: Garden Line is offline. Please check its power and Wi-Fi.",
    ]);
  });

  it("uses the battery-empty wording for a device in low-voltage sleep", async () => {
    await seedClient();
    await seedDevice("D1", {
      nickname: "Garden Line",
      online: false,
      lastSeenMs: T0 - 16 * MIN,
      lowVoltageSleep: true,
    });
    await runAlertPass(T0);
    expect(allSms()[0]).toBe(
      "Hydro Sense: Garden Line is offline because its battery is empty. Please check its solar panel.",
    );
  });

  it("re-arms low battery only above 30 %", async () => {
    await seedClient();
    await seedDevice("D1", { batteryPercent: 15 });
    await runAlertPass(T0);
    const bat = db.collection(C.deviceHealth).doc("D1");
    await bat.update({ batteryPercent: 25 });
    await runAlertPass(T0 + 20 * MIN);
    await bat.update({ batteryPercent: 18 });
    await runAlertPass(T0 + 21 * MIN);
    expect(allSms()).toHaveLength(1);

    await bat.update({ batteryPercent: 35 });
    await runAlertPass(T0 + 22 * MIN);
    await runAlertPass(T0 + 33 * MIN);
    await bat.update({ batteryPercent: 15 });
    await runAlertPass(T0 + 34 * MIN);
    expect(allSms()).toHaveLength(2);
  });

  it("sends nothing for a paused device until the pause ends", async () => {
    await seedClient();
    await seedDevice("D1", {
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 2 * MIN,
      pausedUntilMs: T0 + H,
    });
    await runAlertPass(T0);
    await runAlertPass(T0 + 30 * MIN);
    expect(fake.smsSent).toHaveLength(0);
    await runAlertPass(T0 + H + MIN);
    expect(fake.smsSent).toHaveLength(1);
  });

  it("sends each alert once when two passes overlap (send lease)", async () => {
    await seedClient();
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    await Promise.all([runAlertPass(T0), runAlertPass(T0)]);
    expect(fake.smsSent).toHaveLength(1);
    expect(fake.emailSent).toHaveLength(1);
  });

  it("keeps phone numbers, emails, nicknames and flow data out of error_logs", async () => {
    await seedClient();
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    fake.smsFail = true;
    fake.emailFail = true;
    await runAlertPass(T0);
    const logs = await db.collection(C.errorLogs).get();
    expect(logs.size).toBeGreaterThan(0);
    const all = JSON.stringify(logs.docs.map((d) => d.data()));
    for (const secret of [PHONE, EMAIL, "Garden Line", "No Flow", "16.04", "120.33"]) {
      expect(all).not.toContain(secret);
    }
  });
});

describe("AI summary", () => {
  const change = (before: Record<string, unknown>, after: Record<string, unknown>) => {
    const snap = (d: Record<string, unknown>) => ({ data: () => d, get: (k: string) => d[k] });
    return { data: { before: snap(before), after: snap(after) } } as unknown as Parameters<
      typeof generateClientFlowSummaryOnChange.run
    >[0];
  };

  it("is not called when the status is unchanged (nickname, pause, rate edits)", async () => {
    await seedClient();
    await seedDevice("D1");
    const base = { ownerUid: "client1", flowStatus: "Normal Flow", nickname: "A", flowRate: 8 };
    await generateClientFlowSummaryOnChange.run(change(base, { ...base, nickname: "B" }));
    await generateClientFlowSummaryOnChange.run(change(base, { ...base, pausedUntil: 1 }));
    await generateClientFlowSummaryOnChange.run(change(base, { ...base, flowRate: 12 }));
    expect(fake.modelCalls).toHaveLength(0);

    await generateClientFlowSummaryOnChange.run(change(base, { ...base, flowStatus: "No Flow" }));
    expect(fake.modelCalls).toHaveLength(1);
    expect(fake.modelCalls[0]!.prompt).not.toMatch(/16\.04|120\.33/);
  });

  it("has a 15 min cooldown, broken by a device newly entering No Flow or Offline", async () => {
    await seedClient();
    await seedDevice("D1");
    await seedDevice("D2");
    expect((await refreshSummary(T0)).status).toBe("updated");
    expect((await refreshSummary(T0 + 5 * MIN)).status).toBe("cooldown");

    await setFlow("D1", "No Flow", T0);
    expect((await refreshSummary(T0 + 6 * MIN)).status).toBe("updated");
    expect((await refreshSummary(T0 + 7 * MIN)).status).toBe("cooldown");

    // D2 goes silent; the monitor's offline flip triggers one summary inside the cooldown.
    await db
      .collection(C.deviceHealth)
      .doc("D2")
      .update({ lastSeen: ts(T0 + 7 * MIN - 4 * MIN) });
    await runMonitorPass(T0 + 8 * MIN);
    expect(fake.modelCalls).toHaveLength(3);
    expect(fake.modelCalls[2]!.prompt).toContain("offline");
  });

  it("calls the model once for two parallel refreshes", async () => {
    await seedClient();
    await seedDevice("D1");
    const results = await Promise.all([refreshSummary(T0), refreshSummary(T0)]);
    expect(fake.modelCalls).toHaveLength(1);
    expect(results.map((r) => r.status).sort()).toEqual(["cooldown", "updated"]);
  });

  it("keeps the old text on failure, or writes plain wording when there is none", async () => {
    await seedClient();
    await seedDevice("D1", { nickname: "Garden Line", flowStatus: "No Flow", abnormalSinceMs: T0 });
    fake.modelFail = true;
    const r = await refreshSummary(T0);
    expect(r).toMatchObject({ status: "fallback" });
    const doc = await db.collection(C.aiInsights).doc("client_summary").get();
    expect(doc.get("text")).toBe(
      "1 area needs attention: Garden Line (no flow). Check the valve, pipe, pump or device power.",
    );

    await db
      .collection(C.aiInsights)
      .doc("client_summary")
      .update({ lastAttemptAt: ts(T0 - H) });
    expect((await refreshSummary(T0 + MIN)).status).toBe("kept");
    const errors = await db.collection(C.errorLogs).where("code", "==", "AI_FAILED").get();
    expect(errors.size).toBeGreaterThan(0);
  });
});

describe("calibration", () => {
  async function seedLogs(id: string, n: number, flowRate: number) {
    const batch = db.batch();
    for (let k = 1; k <= n; k++) {
      batch.set(db.collection(C.devices).doc(id).collection(C.flowLogs).doc(), {
        ts: ts(T0 - k * 300 * S),
        flowStatus: "Normal Flow",
        flowRate,
        trigger: "heartbeat",
      });
    }
    batch.set(db.collection(C.devices).doc(id).collection(C.flowLogs).doc(), {
      ts: ts(T0 - 7 * S),
      flowStatus: "No Flow",
      flowRate: 0,
      trigger: "status_change",
    });
    await batch.commit();
  }

  const cutoffs = async (id: string) => (await db.collection(C.devices).doc(id).get()).data()!;

  it("needs 36 samples", async () => {
    await seedDevice("D1");
    await seedLogs("D1", 35, 10);
    expect(await calibrateDevice("D1", T0)).toBe("kept_insufficient");
    await seedLogs("D1", 36, 10);
    expect(await calibrateDevice("D1", T0)).toBe("updated");
  });

  it("keeps the limits when the mean flow is below 1.25", async () => {
    await seedDevice("D1");
    await seedLogs("D1", 50, 1.2);
    expect(await calibrateDevice("D1", T0)).toBe("kept_insufficient");
    expect(fake.modelCalls).toHaveLength(0);
  });

  it("skips a device that alerted in the last 24 h", async () => {
    await seedDevice("D1");
    await seedLogs("D1", 50, 10);
    await db
      .collection(C.alertState)
      .doc("D1__flow")
      .set({ active: false, lastSentAt: ts(T0 - 23 * H) });
    expect(await calibrateDevice("D1", T0)).toBe("kept_recent_alert");
  });

  it("uses valid model output, and the deterministic fallback otherwise", async () => {
    await seedDevice("D1");
    await seedLogs("D1", 40, 10);
    fake.modelReply = () => '{"lowFlowCutoff":1.5,"normalFlowCutoff":5}';
    await calibrateDevice("D1", T0);
    expect(await cutoffs("D1")).toMatchObject({ lowFlowCutoff: 1.5, normalFlowCutoff: 5 });
    expect(fake.modelCalls[0]!.jsonSchema).toBeDefined();
    expect(fake.modelCalls[0]!.prompt).not.toMatch(/Line D1/);

    fake.modelReply = () => '{"lowFlowCutoff":1.5,"normalFlowCutoff":9.5}'; // > 0.8 x mean
    await calibrateDevice("D1", T0);
    expect(await cutoffs("D1")).toMatchObject({ lowFlowCutoff: 1.5, normalFlowCutoff: 5 });
    const fb = await db.collection(C.errorLogs).where("code", "==", "CALIBRATION_FALLBACK").get();
    expect(fb.size).toBe(1);

    fake.modelFail = true;
    await calibrateDevice("D1", T0 + H + 5 * MIN);
    const d = await cutoffs("D1");
    expect(d.calibratedAt).toBeInstanceOf(Timestamp);
  });
});

describe("admin hardware report", () => {
  it("reads only device health and error logs", async () => {
    await seedClient();
    await seedDevice("D1", { nickname: "SECRETNICK", flowStatus: "No Flow", abnormalSinceMs: T0 });
    await db
      .collection(C.errorLogs)
      .doc("e1")
      .set({ deviceId: "D1", code: "SMS_FAILED", message: "x", ts: ts(T0) });
    const facts = await collectHardwareFacts(T0);
    expect(facts.devices[0]).toMatchObject({ id: "D1", batteryPercent: 80, online: true });
    expect(facts.errorCounts).toEqual({ "D1 SMS_FAILED": 1 });

    await generateReport(T0);
    const prompt = fake.modelCalls[0]!.prompt;
    for (const flowData of ["SECRETNICK", "No Flow", "flowRate", "16.04", "120.33", "client"]) {
      expect(prompt).not.toContain(flowData);
    }
    expect(
      (await db.collection(C.aiInsights).doc("admin_diagnostics").get()).get("text"),
    ).toBeTruthy();
  });
});

describe("client account and device admin", () => {
  const admin = <T>(data: T) =>
    ({ auth: { uid: "admin1", token: { role: "admin" } }, data }) as unknown as CallableRequest<T>;
  const input = { name: "Juan", email: "Juan@Example.com", phone: "0917 123 4567" };

  it("creates the client, adopts devices on both docs, and refuses a second client", async () => {
    await seedDevice("D1");
    await db.collection(C.devices).doc("D1").update({ ownerUid: null });
    await db.collection(C.deviceHealth).doc("D1").update({ ownerUid: null });

    const r = await createClientAccount.run(admin({ ...input, setupMethod: "temporary" }));
    expect(r.temporaryPassword).toMatch(/^[A-Za-z2-9]{12}$/);
    expect(r.adopted).toBe(1);
    const uid = r.uid;
    expect((await getAuth().getUser(uid)).customClaims).toEqual({ role: "client" });
    expect((await db.collection(C.users).doc(uid).get()).data()).toMatchObject({
      phone: "639171234567",
      email: "juan@example.com",
      mustChangePassword: true,
    });
    expect((await db.collection(C.devices).doc("D1").get()).get("ownerUid")).toBe(uid);
    expect((await db.collection(C.deviceHealth).doc("D1").get()).get("ownerUid")).toBe(uid);

    await expect(
      createClientAccount.run(
        admin({ ...input, email: "other@example.com", setupMethod: "email" }),
      ),
    ).rejects.toMatchObject({ code: "already-exists", details: { code: "CLIENT_EXISTS" } });
  });

  it("validates input and refuses non-admins", async () => {
    await expect(
      createClientAccount.run(admin({ ...input, phone: "12345", setupMethod: "email" })),
    ).rejects.toMatchObject({ details: { code: "PHONE_INVALID" } });
    const client = {
      auth: { uid: "c", token: { role: "client" } },
      data: input,
    } as unknown as CallableRequest;
    await expect(createClientAccount.run(client)).rejects.toMatchObject({
      code: "permission-denied",
    });
  });

  it("emails a setup link, and reports when the email cannot be sent", async () => {
    const ok = await createClientAccount.run(admin({ ...input, setupMethod: "email" }));
    expect(ok.emailSent).toBe(true);
    expect(fake.emailSent[0]!.text).toMatch(/https?:\/\/\S+/);

    await fetch(
      `http://${FIRESTORE}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`,
      { method: "DELETE" },
    );
    await fetch(`http://${AUTH}/emulator/v1/projects/${PROJECT}/accounts`, { method: "DELETE" });
    fake.emailFail = true;
    const failed = await createClientAccount.run(admin({ ...input, setupMethod: "email" }));
    expect(failed.emailSent).toBe(false);
    expect((await db.collection(C.errorLogs).where("code", "==", "EMAIL_FAILED").get()).size).toBe(
      1,
    );
  });
});
