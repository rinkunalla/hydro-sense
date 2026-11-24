// v3 acceptance tests for alerts, weekly calibration, device admin and the
// v2 -> v3 migration. Run in-process against the Firestore, Auth and Realtime
// Database emulators with fake providers; time is passed explicitly, never
// waited for. Run WITHOUT the Functions emulator (npm run test:inprocess).
import { getAuth } from "firebase-admin/auth";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/https";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { addAllowedDevice, removeDevice, updateDevice } from "../src/admin/devices";
import { runAlertPass } from "../src/alerts/alertPass";
import { claimPushTokenFor } from "../src/alerts/pushTokens";
import { calibrateDevice } from "../src/calibration/calibrate";
import { C, PIPELINE_DOC, db, liveRef, rtdb, stateRef, ts } from "../src/lib/db";
import { setProviders, type Providers } from "../src/lib/providers";
import { manilaDateKey } from "../src/lib/time";
import { locatePlace, setPlacesHttp, suggestPlaces } from "../src/maps/places";
import { migrateV3 } from "../src/migration/v3";
import { runMonitorPass } from "../src/monitor/monitorDevices";

const PROJECT = process.env.GCLOUD_PROJECT ?? "hydro-sense-dc836";
const FIRESTORE = process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080";
const AUTH = process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099";

const S = 1000;
const MIN = 60 * S;
const H = 60 * MIN;
const PHONE = "639171234567";
const EMAIL = "ana@example.com";

class Fake implements Providers {
  smsSent: { to: string; msg: string }[] = [];
  emailSent: { to: string; subject: string; text: string }[] = [];
  smsFail = false;
  emailFail = false;

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
  pushSent: { fids: string[]; title: string; body: string; data: Record<string, string> }[] = [];
  push = {
    send: async (fids: string[], title: string, body: string, data: Record<string, string>) => {
      this.pushSent.push({ fids, title, body, data });
      return { sent: fids.length, stale: [] as string[] };
    },
  };
}

let fake: Fake;
let T0: number;

interface DeviceSeed {
  nickname?: string;
  sensorType?: string;
  flowStatus?: string | null;
  flowRate?: number;
  abnormalSinceMs?: number | null;
  online?: boolean;
  lastSeenMs?: number | null;
  batteryPercent?: number | null;
  lowVoltageSleep?: boolean;
}

/** A staff member (role "user"). null contact = none. */
async function seedStaff(
  uid = "u1",
  o: { phone?: string | null; email?: string | null; status?: "active" | "disabled" } = {},
) {
  await db
    .collection(C.users)
    .doc(uid)
    .set({
      role: "user",
      name: uid,
      username: uid,
      phone: o.phone === undefined ? PHONE : o.phone,
      email: o.email === undefined ? EMAIL : o.email,
      status: o.status ?? "active",
    });
}

const pushToken = (uid: string, fid: string) =>
  db
    .collection(C.users)
    .doc(uid)
    .collection(C.pushTokens)
    .doc(fid)
    .set({ platform: "android", fid });

async function seedDevice(id: string, o: DeviceSeed = {}) {
  const t = (v: number | null | undefined) => (v === null || v === undefined ? null : ts(v));
  await db
    .collection(C.devices)
    .doc(id)
    .set({
      nickname: o.nickname ?? `Line ${id}`,
      sensorType: o.sensorType ?? "yf_s201",
      flowStatus: o.flowStatus === undefined ? "Normal Flow" : o.flowStatus,
      flowRate: o.flowRate ?? 8,
      abnormalSince: t(o.abnormalSinceMs),
      gpsLat: 16.04,
      gpsLng: 120.33,
      manualLat: null,
      manualLng: null,
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2.0,
      userNormalCutoff: null,
      calibratedAt: null,
      statusChangedAt: ts(T0 - H),
      updatedAt: ts(T0),
    });
  await db
    .collection(C.deviceHealth)
    .doc(id)
    .set({ registeredAt: ts(T0 - H), firmware: "0.3.0" });
  // What the monitor and alerts read.
  await liveRef(id).set({
    online: o.online ?? true,
    lastSeen: o.lastSeenMs === undefined ? T0 : o.lastSeenMs,
    flowStatus: o.flowStatus === undefined ? "Normal Flow" : o.flowStatus,
    flowRate: o.flowRate ?? 8,
    abnormalSince: o.abnormalSinceMs ?? null,
    batteryPercent: o.batteryPercent === undefined ? 80 : o.batteryPercent,
    batteryFault: false,
    lowVoltageSleep: o.lowVoltageSleep ?? false,
  });
}

const setFlow = (id: string, flowStatus: string, abnormalSinceMs: number | null) =>
  liveRef(id).update({ flowStatus, abnormalSince: abnormalSinceMs });

const allSms = () => fake.smsSent.map((s) => s.msg);
const allMail = () => fake.emailSent.map((m) => m.text);
const noFlow = () => ({ flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });

beforeEach(async () => {
  await fetch(`http://${FIRESTORE}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {
    method: "DELETE",
  });
  await fetch(`http://${AUTH}/emulator/v1/projects/${PROJECT}/accounts`, { method: "DELETE" });
  fake = new Fake();
  setProviders(fake);
  T0 = Math.floor(Date.now() / MIN) * MIN;
  await rtdb.ref().set(null);
  // Admin callables need a live admin record, not only the claim. No contacts:
  // this admin receives no alerts unless a test gives them one.
  await db.collection(C.admins).doc("admin1").set({ name: "A", status: "active" });
});

afterAll(() => setProviders(null));

describe("alerts", () => {
  it("needs 30 s of Low/No Flow, then sends one SMS and one email", async () => {
    await seedStaff();
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 29 * S,
    });
    expect((await runAlertPass(T0)).sent).toHaveLength(0);

    const r = await runAlertPass(T0 + S);
    expect(r.users.u1).toMatchObject({ push: "none", sms: "sent", email: "sent" });
    expect(allSms()).toEqual([
      "HydroSense: No water is flowing at Garden Line. Please check the pipe, valve or pump.",
    ]);
    expect(fake.smsSent[0]!.to).toBe(PHONE);
    expect(fake.emailSent[0]).toMatchObject({
      to: EMAIL,
      subject: "Hydro Sense alert: Garden Line - No flow",
    });
  });

  it("locks for 6 h, sends two reminders, then stays silent", async () => {
    await seedStaff();
    await seedDevice("D1", { nickname: "Garden Line", ...noFlow() });
    for (const t of [0, 1 * H, 5 * H, 6 * H, 7 * H, 12 * H, 18 * H, 30 * H])
      await runAlertPass(T0 + t);
    expect(allSms()).toHaveLength(3);
    expect(allSms()[1]).toContain("Reminder: still no water at Garden Line");
  });

  it("does not set the lock when every tried channel fails; Low Flow now goes by SMS too", async () => {
    await seedStaff();
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "Low Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    fake.smsFail = true;
    fake.emailFail = true;
    expect((await runAlertPass(T0)).sent).toHaveLength(0);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(false);

    fake.smsFail = false;
    fake.emailFail = false;
    const r = await runAlertPass(T0 + MIN);
    expect(r.users.u1).toMatchObject({ push: "none", sms: "sent", email: "sent" });
    expect(allSms()).toEqual([
      "HydroSense: Garden Line has low water flow. Please check the pipe or valve.",
    ]);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(true);
  });

  it("re-arms only after 10 min of Normal; a Low/Normal flap sends nothing", async () => {
    await seedStaff();
    await seedDevice("D1", { flowStatus: "Low Flow", abnormalSinceMs: T0 - 2 * MIN });
    await runAlertPass(T0);
    await setFlow("D1", "Normal Flow", null);
    await runAlertPass(T0 + 1 * MIN);
    await runAlertPass(T0 + 8 * MIN);
    await setFlow("D1", "Low Flow", T0 + 8.5 * MIN); // flap inside 10 min
    await runAlertPass(T0 + 10 * MIN);
    expect(allMail()).toHaveLength(1);

    await setFlow("D1", "Normal Flow", null);
    await runAlertPass(T0 + 11 * MIN);
    await runAlertPass(T0 + 22 * MIN); // 11 min of Normal: re-armed
    await setFlow("D1", "Low Flow", T0 + 23 * MIN);
    await runAlertPass(T0 + 25 * MIN);
    expect(allMail()).toHaveLength(2);
  });

  it("escalates Low -> No once; No -> Low sends nothing", async () => {
    await seedStaff();
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
    expect(fake.emailSent.map((m) => m.subject)).toEqual([
      "Hydro Sense alert: Garden Line - Low flow",
      "Hydro Sense alert: Garden Line - No flow",
    ]);
    expect(allSms()).toEqual([
      "HydroSense: Garden Line has low water flow. Please check the pipe or valve.",
      "HydroSense: No water is flowing at Garden Line. Please check the pipe, valve or pump.",
    ]);
  });

  it("batches 3 failing devices into one SMS and one email within 160 characters", async () => {
    await seedStaff();
    for (const id of ["D1", "D2", "D3"]) {
      await seedDevice(id, { nickname: `${id} ${"x".repeat(21)}`, ...noFlow() });
    }
    const r = await runAlertPass(T0);
    expect(r.sent).toHaveLength(3);
    expect(fake.smsSent).toHaveLength(1);
    expect(fake.emailSent).toHaveLength(1);
    expect(allSms()[0]!.length).toBeLessThanOrEqual(160);
    expect(allSms()[0]).toMatch(
      /^HydroSense: No water at 3 areas: D1 x+, D2 .+, D3 .+\. Open Hydro Sense\.$/,
    );
    expect(fake.emailSent[0]!.subject).toBe("Hydro Sense alert: 3 areas need attention");
  });

  it("caps each channel at 10 per day per person, then sends one digest", async () => {
    await seedStaff();
    await db
      .collection(C.alertDaily)
      .doc(`${manilaDateKey(T0)}__u1`)
      .set({ smsCount: 10, emailCount: 3 });
    await seedDevice("D1", noFlow());
    const r1 = await runAlertPass(T0);
    expect(r1.users.u1).toMatchObject({ sms: "digest", email: "sent" });
    expect(allSms()).toEqual(["HydroSense: More alerts today. Open Hydro Sense for live status."]);

    await seedDevice("D2", noFlow());
    const r2 = await runAlertPass(T0 + MIN);
    expect(r2.users.u1).toMatchObject({ sms: "capped", email: "sent" });
    expect(fake.smsSent).toHaveLength(1);
    const cap = await db.collection(C.errorLogs).where("code", "==", "ALERT_CAP_REACHED").get();
    expect(cap.size).toBe(1);
  });

  it("shows Offline at 3 min (no heartbeat reported) and alerts by SMS and email in the same pass", async () => {
    await seedStaff();
    await seedDevice("D1", { nickname: "Garden Line", online: true, lastSeenMs: T0 - 181_000 });
    const m = await runMonitorPass(T0);
    expect(m.flipped).toEqual(["D1"]);
    expect(allSms()).toEqual([
      "HydroSense: Garden Line is offline. Please check its power and Wi-Fi.",
    ]);
    expect(fake.emailSent).toHaveLength(1);
  });

  it("does not alert an offline device before 40 s of silence", async () => {
    await seedStaff();
    await seedDevice("D1", { nickname: "Garden Line", online: false, lastSeenMs: T0 - 30_000 });
    await runAlertPass(T0);
    expect(fake.emailSent).toHaveLength(0);
    await runAlertPass(T0 + 10_000);
    expect(fake.emailSent.map((m) => m.subject)).toEqual([
      "Hydro Sense alert: Garden Line - Offline",
    ]);
    expect(fake.smsSent).toHaveLength(1);
  });

  it("uses the battery-empty wording for a device in low-voltage sleep", async () => {
    await seedStaff();
    await seedDevice("D1", {
      nickname: "Garden Line",
      online: false,
      lastSeenMs: T0 - 16 * MIN,
      lowVoltageSleep: true,
    });
    await runAlertPass(T0);
    expect(allMail()[0]).toContain("Garden Line is offline because its battery is empty.");
  });

  it("low battery never goes by SMS and re-arms only above 30 %", async () => {
    await seedStaff();
    await seedDevice("D1", { batteryPercent: 15 });
    await runAlertPass(T0);
    const bat = liveRef("D1");
    await bat.update({ batteryPercent: 25 });
    await runAlertPass(T0 + 20 * MIN);
    await bat.update({ batteryPercent: 18 });
    await runAlertPass(T0 + 21 * MIN);
    expect(allMail()).toHaveLength(1);

    await bat.update({ batteryPercent: 35 });
    await runAlertPass(T0 + 22 * MIN);
    await runAlertPass(T0 + 33 * MIN);
    await bat.update({ batteryPercent: 15 });
    await runAlertPass(T0 + 34 * MIN);
    expect(allMail()).toHaveLength(2);
    expect(fake.smsSent).toHaveLength(0);
  });

  it("sends each alert once when two passes overlap (send lease)", async () => {
    await seedStaff();
    await seedDevice("D1", noFlow());
    await Promise.all([runAlertPass(T0), runAlertPass(T0)]);
    expect(fake.smsSent).toHaveLength(1);
    expect(fake.emailSent).toHaveLength(1);
  });

  it("keeps phone numbers, emails, names and flow data out of error_logs", async () => {
    await seedStaff();
    await seedDevice("D1", { nickname: "Garden Line", ...noFlow() });
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

  it("sets the weekly formula's cutoffs and calibratedAt, and mirrors them", async () => {
    await seedDevice("D1");
    await seedLogs("D1", 40, 10);
    expect(await calibrateDevice("D1", T0)).toBe("updated");
    const d = (await db.collection(C.devices).doc("D1").get()).data()!;
    expect(d).toMatchObject({ lowFlowCutoff: 1.5, normalFlowCutoff: 5 }); // 0.15 x 10, 0.5 x 10
    expect(d.calibratedAt).toBeInstanceOf(Timestamp);
    expect((await stateRef("D1").get()).val()).toMatchObject({ normalFlowCutoff: 5 });
    expect((await db.collection(C.errorLogs).get()).size).toBe(0);
  });
});

describe("alert channels", () => {
  it("push carries every type with only deviceId or kind in its data", async () => {
    await seedStaff();
    await pushToken("u1", "fid-1");
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "Low Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ push: "sent", sms: "sent", email: "sent" });
    expect(fake.pushSent).toEqual([
      {
        fids: ["fid-1"],
        title: "Low water flow at Garden Line",
        body: "Please check the pipe or valve.",
        data: { deviceId: "D1" },
      },
    ]);
  });

  it("a mixed batch: push and email list all, the SMS all but low battery", async () => {
    await seedStaff();
    await pushToken("u1", "fid-1");
    await seedDevice("D1", { nickname: "Garden", ...noFlow() });
    await seedDevice("D2", {
      nickname: "Kitchen",
      flowStatus: "Low Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    await seedDevice("D3", { nickname: "Orchard", batteryPercent: 10 });
    await runAlertPass(T0);
    expect(allSms()).toEqual([
      "HydroSense: 2 areas need attention: Garden (no flow), Kitchen (low flow). Open Hydro Sense.",
    ]);
    expect(fake.pushSent[0]).toMatchObject({
      title: "3 areas need attention",
      body: "Garden (no flow), Kitchen (low flow), Orchard (low battery).",
      data: { kind: "batch" },
    });
    expect(fake.emailSent[0]!.subject).toBe("Hydro Sense alert: 3 areas need attention");
  });

  it("a staff member with no mobile and no email gets push only, and counts only push", async () => {
    await seedStaff("u1", { phone: null, email: null });
    await pushToken("u1", "fid-1");
    await seedDevice("D1", noFlow());
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ push: "sent", sms: "none", email: "none" });
    expect(fake.smsSent.length + fake.emailSent.length).toBe(0);
    const day = (
      await db
        .collection(C.alertDaily)
        .doc(`${manilaDateKey(T0)}__u1`)
        .get()
    ).data()!;
    expect(day).toEqual({ pushCount: 1 });
    expect((await db.collection(C.errorLogs).get()).size).toBe(0);
  });

  it("nobody reachable: nothing is sent, and the lock is still set", async () => {
    await seedStaff("u1", { phone: null, email: null });
    await seedDevice("D1", noFlow());
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ push: "none", sms: "none", email: "none" });
    expect(fake.smsSent.length + fake.emailSent.length + fake.pushSent.length).toBe(0);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(true);
  });

  it("deletes installation IDs that FCM reports as gone", async () => {
    await seedStaff();
    await pushToken("u1", "fid-old");
    await pushToken("u1", "fid-new");
    fake.push.send = async (fids, title, body, data) => {
      fake.pushSent.push({ fids, title, body, data });
      return { sent: 1, stale: ["fid-old"] };
    };
    await seedDevice("D1", noFlow());
    await runAlertPass(T0);
    const left = await db.collection(C.users).doc("u1").collection(C.pushTokens).get();
    expect(left.docs.map((d) => d.id)).toEqual(["fid-new"]);
  });

  it("push has its own daily cap of 10, then one digest", async () => {
    await seedStaff();
    await pushToken("u1", "fid-1");
    await db
      .collection(C.alertDaily)
      .doc(`${manilaDateKey(T0)}__u1`)
      .set({ pushCount: 10 });
    await seedDevice("D1", noFlow());
    const r = await runAlertPass(T0);
    expect(r.users.u1!.push).toBe("digest");
    expect(fake.pushSent[0]).toMatchObject({ title: "More alerts today", data: { kind: "batch" } });
  });
});

describe("alerts go to every active member (D65)", () => {
  async function seedTeam() {
    await seedStaff("u1");
    await seedStaff("u2", { phone: "639170000002", email: "ben@example.com" });
    await seedStaff("u3", { phone: "639170000003", email: "cy@example.com", status: "disabled" });
    await pushToken("u1", "fid-u1");
    await pushToken("u2", "fid-u2");
    await db
      .collection(C.admins)
      .doc("admin1")
      .set({ name: "Owner", status: "active", phone: "639170000009", email: "owner@example.com" });
    await db
      .collection(C.admins)
      .doc("admin2")
      .set({ name: "New", status: "invited", email: "new@example.com" });
  }

  it("every active staff member and admin gets the same batch; disabled and invited get nothing", async () => {
    await seedTeam();
    await seedDevice("D1", { nickname: "A line", ...noFlow() });
    await seedDevice("D2", { nickname: "B line", ...noFlow() });
    const r = await runAlertPass(T0);
    expect(Object.keys(r.users).sort()).toEqual(["admin1", "u1", "u2"]);
    expect(r.sent.map((i) => i.deviceId).sort()).toEqual(["D1", "D2"]);
    expect(fake.smsSent.map((m) => m.to).sort()).toEqual(
      [PHONE, "639170000002", "639170000009"].sort(),
    );
    for (const m of fake.smsSent) expect(m.msg).toContain("A line");
    expect(fake.emailSent.map((m) => m.to).sort()).toEqual(
      [EMAIL, "ben@example.com", "owner@example.com"].sort(),
    );
    // The admin has no app: push goes to staff phones only.
    expect(r.users.admin1!.push).toBe("none");
    expect(fake.pushSent.map((p) => p.fids[0]).sort()).toEqual(["fid-u1", "fid-u2"]);
  });

  it("each device's lock is claimed once, not per person: the next pass sends nothing", async () => {
    await seedTeam();
    await seedDevice("D1", noFlow());
    await runAlertPass(T0);
    const before = fake.smsSent.length;
    expect((await runAlertPass(T0 + MIN)).sent).toHaveLength(0);
    expect(fake.smsSent).toHaveLength(before);
  });

  it("counts caps per person, so one person's cap never silences another", async () => {
    await seedTeam();
    await db
      .collection(C.alertDaily)
      .doc(`${manilaDateKey(T0)}__u1`)
      .set({ smsCount: 10, smsDigestSent: true });
    await seedDevice("D1", noFlow());
    const r = await runAlertPass(T0);
    expect(r.users.u1!.sms).toBe("capped");
    expect(r.users.u2!.sms).toBe("sent");
    expect(r.users.admin1!.sms).toBe("sent");
  });

  it("stops alert SMS at the project ceiling of 100 per day", async () => {
    await seedStaff("u1");
    await db.collection(C.alertDaily).doc(manilaDateKey(T0)).set({ smsCount: 100 });
    await seedDevice("D1", noFlow());
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ sms: "capped", email: "sent" });
    expect(fake.smsSent).toHaveLength(0);
    const logs = await db
      .collection(C.errorLogs)
      .where("code", "==", "SMS_PROJECT_CAP_REACHED")
      .get();
    expect(logs.size).toBe(1);
  });

  it("adds each SMS sent to anyone to the project count", async () => {
    await seedTeam();
    await seedDevice("D1", noFlow());
    await runAlertPass(T0);
    const day = await db.collection(C.alertDaily).doc(manilaDateKey(T0)).get();
    expect(day.get("smsCount")).toBe(3);
  });
});

const asAdmin = <T>(data: T, uid = "admin1") =>
  ({ auth: { uid, token: { role: "admin" } }, data }) as unknown as CallableRequest<T>;
const asStaff = <T>(data: T) =>
  ({ auth: { uid: "u1", token: { role: "user" } }, data }) as unknown as CallableRequest<T>;

describe("device admin (D62, D63, D69)", () => {
  const device = async (id: string) => (await db.collection(C.devices).doc(id).get()).data()!;
  const state = async (id: string) => (await stateRef(id).get()).val() as Record<string, unknown>;

  it("adding an ID creates its records at once, Not set up yet, with name and sensor", async () => {
    await addAllowedDevice.run(
      asAdmin({ deviceId: "a4:f0:0f:69:36:b0", name: " Main pipe ", sensorType: "zj_dn50" }),
    );
    expect((await db.collection(C.allowedDevices).doc("A4F00F6936B0").get()).exists).toBe(true);
    expect(await device("A4F00F6936B0")).toMatchObject({
      nickname: "Main pipe",
      sensorType: "zj_dn50",
      lowFlowCutoff: 5,
      normalFlowCutoff: 20,
      flowStatus: null,
    });
    const health = (await db.collection(C.deviceHealth).doc("A4F00F6936B0").get()).data()!;
    expect(health.registeredAt).toBeNull();
    expect(await state("A4F00F6936B0")).toMatchObject({
      sensorType: "zj_dn50",
      normalFlowCutoff: 20,
    });

    await addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1" }));
    expect(await device("AAAAAAAAAAA1")).toMatchObject({
      nickname: "Device AAA1",
      sensorType: "yf_s201",
    });
  });

  it("refuses a duplicate, a bad ID or sensor, and staff", async () => {
    await addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1" }));
    await expect(addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1" }))).rejects.toMatchObject(
      {
        details: { code: "DEVICE_EXISTS" },
      },
    );
    await expect(addAllowedDevice.run(asAdmin({ deviceId: "123" }))).rejects.toMatchObject({
      details: { code: "DEVICE_ID_INVALID" },
    });
    await expect(
      addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA2", sensorType: "rotor" })),
    ).rejects.toMatchObject({ details: { code: "SENSOR_INVALID" } });
    await seedStaff();
    await expect(addAllowedDevice.run(asStaff({ deviceId: "AAAAAAAAAAA3" }))).rejects.toMatchObject(
      {
        details: { code: "NOT_ADMIN" },
      },
    );
  });

  it("updateDevice sets name, pin and the admin's limit within the sensor's range", async () => {
    await addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1" }));
    await updateDevice.run(
      asAdmin({
        deviceId: "AAAAAAAAAAA1",
        name: "Tank",
        manualLat: 16.1,
        manualLng: 120.5,
        userNormalCutoff: 3,
      }),
    );
    expect(await device("AAAAAAAAAAA1")).toMatchObject({
      nickname: "Tank",
      manualLat: 16.1,
      manualLng: 120.5,
      userNormalCutoff: 3,
    });
    expect(await state("AAAAAAAAAAA1")).toMatchObject({ lowFlowCutoff: 0.2, normalFlowCutoff: 3 });

    await updateDevice.run(
      asAdmin({
        deviceId: "AAAAAAAAAAA1",
        manualLat: null,
        manualLng: null,
        userNormalCutoff: null,
      }),
    );
    expect(await device("AAAAAAAAAAA1")).toMatchObject({ manualLat: null, userNormalCutoff: null });

    for (const [data, code] of [
      [{ userNormalCutoff: 31 }, "CUTOFF_INVALID"],
      [{ manualLat: 91, manualLng: 0 }, "PIN_INVALID"],
      [{ manualLat: 16 }, "PIN_INVALID"],
      [{ name: " " }, "NAME_INVALID"],
    ] as const) {
      await expect(
        updateDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1", ...data })),
      ).rejects.toMatchObject({
        details: { code },
      });
    }
    await expect(
      updateDevice.run(asAdmin({ deviceId: "BBBBBBBBBBB1", name: "X" })),
    ).rejects.toMatchObject({
      details: { code: "DEVICE_NOT_FOUND" },
    });
  });

  it("a new sensor type starts over from its starter limits and reaches the device's state", async () => {
    await addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1" }));
    await db
      .collection(C.devices)
      .doc("AAAAAAAAAAA1")
      .update({
        lowFlowCutoff: 1.5,
        normalFlowCutoff: 5,
        userNormalCutoff: 3,
        calibratedAt: ts(T0),
      });
    await updateDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1", sensorType: "zj_dn50" }));
    expect(await device("AAAAAAAAAAA1")).toMatchObject({
      sensorType: "zj_dn50",
      lowFlowCutoff: 5,
      normalFlowCutoff: 20,
      userNormalCutoff: null,
      calibratedAt: null,
    });
    expect(await state("AAAAAAAAAAA1")).toMatchObject({
      sensorType: "zj_dn50",
      normalFlowCutoff: 20,
    });
    // The DN50's own range: 3 L/min is below what it can read.
    await expect(
      updateDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1", userNormalCutoff: 3 })),
    ).rejects.toMatchObject({ details: { code: "CUTOFF_INVALID" } });
  });

  it("removeDevice needs the typed name and deletes the device, its history and its place at once", async () => {
    await addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1", name: "Tank" }));
    await addAllowedDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA2", name: "Main" }));
    await db.collection(C.deviceSecrets).doc("AAAAAAAAAAA1").set({ tokenHash: "h" });
    await db.collection(C.problems).add({ deviceId: "AAAAAAAAAAA1", type: "no_flow" });
    await db
      .collection(C.readings)
      .doc("AAAAAAAAAAA1_2027-01-01")
      .set({ deviceId: "AAAAAAAAAAA1" });
    await db.collection(C.alertState).doc("AAAAAAAAAAA1__flow").set({ active: true });
    await liveRef("AAAAAAAAAAA1").set({ online: true });
    await rtdb.ref("series/AAAAAAAAAAA1/2027-01-01/1").set(4);
    await db
      .collection(C.pipelines)
      .doc(PIPELINE_DOC)
      .set({
        name: "Line",
        source: { name: "Spring", lat: 16, lng: 120 },
        branches: [
          {
            id: "b1",
            endName: "End",
            endLat: 16,
            endLng: 120,
            deviceIds: ["AAAAAAAAAAA2", "AAAAAAAAAAA1"],
          },
        ],
      });

    await expect(
      removeDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1", confirmName: "Main" })),
    ).rejects.toMatchObject({ details: { code: "CONFIRM_MISMATCH" } });
    await removeDevice.run(asAdmin({ deviceId: "AAAAAAAAAAA1", confirmName: " tank " }));

    for (const p of [
      `allowed_devices/AAAAAAAAAAA1`,
      `devices/AAAAAAAAAAA1`,
      `device_health/AAAAAAAAAAA1`,
      `device_secrets/AAAAAAAAAAA1`,
      `alert_state/AAAAAAAAAAA1__flow`,
      `readings/AAAAAAAAAAA1_2027-01-01`,
    ]) {
      expect((await db.doc(p).get()).exists, p).toBe(false);
    }
    expect(
      (await db.collection(C.problems).where("deviceId", "==", "AAAAAAAAAAA1").get()).size,
    ).toBe(0);
    expect((await rtdb.ref("live/AAAAAAAAAAA1").get()).exists()).toBe(false);
    expect((await rtdb.ref("series/AAAAAAAAAAA1").get()).exists()).toBe(false);
    const pipe = (await db.collection(C.pipelines).doc(PIPELINE_DOC).get()).data()!;
    expect(pipe.branches[0].deviceIds).toEqual(["AAAAAAAAAAA2"]);
    expect((await db.collection(C.devices).doc("AAAAAAAAAAA2").get()).exists).toBe(true);
  });
});

describe("v2 -> v3 migration", () => {
  async function seedV2() {
    const auth = getAuth();
    await auth.createUser({ uid: "owner", email: "owner@example.com", password: "secret123" });
    await auth.setCustomUserClaims("owner", { role: "user" });
    await auth.createUser({ uid: "ana", email: "Ana.Reyes@example.com", password: "secret123" });
    await auth.setCustomUserClaims("ana", { role: "user" });
    await auth.createUser({ uid: "boss", email: "boss@example.com", password: "secret123" });
    await auth.setCustomUserClaims("boss", { role: "admin" });
    await db
      .collection(C.admins)
      .doc("boss")
      .set({ name: "Boss", email: "boss@example.com", status: "active" });
    const v2User = (name: string, email: string, phone: string) => ({
      role: "user",
      name,
      email,
      phone,
      passwordSet: true,
      deviceCount: 1,
      alertPrefs: { push: true, sms: true, email: false },
      status: "active",
      suspendedAt: null,
      purgeAfter: null,
      deletionRequestedAt: null,
    });
    await db
      .collection(C.users)
      .doc("owner")
      .set(v2User("Mr. Owner", "owner@example.com", "639170000001"));
    await db
      .collection(C.users)
      .doc("ana")
      .set(v2User("Ana", "ana.reyes@example.com", "639170000002"));
    await db
      .collection(C.users)
      .doc("owner")
      .collection(C.pushTokens)
      .doc("fid1")
      .set({ fid: "fid1" });
    await db.collection(C.devices).doc("D0000000AAA1").set({
      ownerUid: "owner",
      nickname: "Device AAA1",
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2,
    });
    await db
      .collection(C.devices)
      .doc("D0000000AAA2")
      .set({
        ownerUid: "owner",
        nickname: "Device AAA2",
        removedAt: ts(T0 - H),
        purgeAfter: ts(T0 + H),
      });
    await db.collection(C.deviceHealth).doc("D0000000AAA1").set({ ownerUid: "owner" });
    await db
      .collection(C.allowedDevices)
      .doc("D0000000AAA1")
      .set({ addedAt: ts(T0), label: "Unit 1" });
    await db
      .collection(C.problems)
      .doc("p1")
      .set({ ownerUid: "owner", deviceId: "D0000000AAA1", note: "x" });
    await db.collection(C.pipelines).doc("owner").set({ name: "Owner line", branches: [] });
    await db.collection(C.pipelines).doc("ana").set({ name: "Ana line", branches: [] });
    await db.collection("admin_audit").doc("a1").set({ action: "user_deleted" });
    await db.collection("password_resets").doc("ana").set({ codeHash: "h" });
    await liveRef("D0000000AAA1").set({ ownerUid: "owner", removed: false, online: true });
    await stateRef("D0000000AAA1").set({ ownerUid: "owner", removed: false, known: true });
  }

  it("dry run lists every change and changes nothing", async () => {
    await seedV2();
    const r = await migrateV3({ apply: false, ownerUid: "owner", nowMs: T0 });
    expect(r.applied).toBe(false);
    expect(r.steps.length).toBeGreaterThan(5);
    expect((await db.collection(C.users).doc("owner").get()).exists).toBe(true);
    expect((await db.collection(C.devices).doc("D0000000AAA1").get()).get("ownerUid")).toBe(
      "owner",
    );
  });

  it("applies the v3 shape, and a second run changes nothing", async () => {
    await seedV2();
    const r = await migrateV3({ apply: true, ownerUid: "owner", nowMs: T0 });
    expect(r.problems).toEqual(["pipelines/ana belonged to another user; deleted"]);

    // The owner is now an admin with the same account.
    expect((await getAuth().getUser("owner")).customClaims).toMatchObject({ role: "admin" });
    expect((await db.collection(C.admins).doc("owner").get()).data()).toMatchObject({
      name: "Mr. Owner",
      email: "owner@example.com",
      phone: "639170000001",
      status: "active",
    });
    expect((await db.collection(C.users).doc("owner").get()).exists).toBe(false);

    // Ana is staff with a username; her real email stays for alerts.
    const ana = (await db.collection(C.users).doc("ana").get()).data()!;
    expect(ana.username).toBe((await getAuth().getUser("ana")).email!.split("@")[0]);
    expect((await getAuth().getUser("ana")).email).toMatch(/@staff\.hydrosense\.invalid$/);
    expect(ana.email).toBe("ana.reyes@example.com");
    for (const f of ["deviceCount", "alertPrefs", "passwordSet", "purgeAfter"])
      expect(ana).not.toHaveProperty(f);

    // Devices.
    const d1 = (await db.collection(C.devices).doc("D0000000AAA1").get()).data()!;
    expect(d1).toMatchObject({ nickname: "Unit 1", sensorType: "yf_s201" });
    expect(d1).not.toHaveProperty("ownerUid");
    expect((await db.collection(C.devices).doc("D0000000AAA2").get()).exists).toBe(false);
    expect(
      (await db.collection(C.allowedDevices).doc("D0000000AAA1").get()).data(),
    ).not.toHaveProperty("label");
    expect(
      (await db.collection(C.deviceHealth).doc("D0000000AAA1").get()).data(),
    ).not.toHaveProperty("ownerUid");
    expect((await db.collection(C.problems).doc("p1").get()).data()).toEqual({
      deviceId: "D0000000AAA1",
    });

    // One pipeline; v2-only records gone; members and the live channel.
    expect((await db.collection(C.pipelines).doc(PIPELINE_DOC).get()).get("name")).toBe(
      "Owner line",
    );
    expect((await db.collection(C.pipelines).get()).size).toBe(1);
    expect((await db.collection("admin_audit").get()).size).toBe(0);
    expect((await db.collection("password_resets").get()).size).toBe(0);
    expect((await rtdb.ref("members").get()).val()).toEqual({ owner: true, ana: true, boss: true });
    expect((await liveRef("D0000000AAA1").get()).val()).toEqual({ online: true });
    expect((await stateRef("D0000000AAA1").get()).val()).toMatchObject({ sensorType: "yf_s201" });
    expect((await stateRef("D0000000AAA1").get()).val()).not.toHaveProperty("ownerUid");

    const again = await migrateV3({ apply: true, ownerUid: "owner", nowMs: T0 });
    expect(again.steps).toEqual([]);
  });
});

describe("place search (Google Places, admins only in v3)", () => {
  const sent: { url: string; headers: Record<string, string>; body?: unknown }[] = [];
  let failNext = false;
  const SESSION = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d";

  beforeAll(() =>
    setPlacesHttp({
      async post(url, headers, body) {
        sent.push({ url, headers, body });
        if (failNext) throw new Error("HTTP 500");
        return {
          suggestions: [
            {
              placePrediction: {
                placeId: "ChIJsm1",
                text: { text: "SM City Rosales, Rosales, Pangasinan" },
                structuredFormat: {
                  mainText: { text: "SM City Rosales" },
                  secondaryText: { text: "Rosales, Pangasinan, Philippines" },
                },
              },
            },
            { queryPrediction: { text: { text: "sm city" } } },
          ],
        };
      },
      async get(url, headers) {
        sent.push({ url, headers });
        return { location: { latitude: 15.89, longitude: 120.6 } };
      },
    }),
  );
  afterAll(() => setPlacesHttp(null));
  beforeEach(() => {
    sent.length = 0;
    failNext = false;
  });

  it("suggests places in the Philippines near the map, then locates the pick", async () => {
    const out = await suggestPlaces(
      "admin1",
      { input: "  sm  city ", sessionToken: SESSION, near: { lat: 16, lng: 120.4 } },
      "KEY",
    );
    expect(out).toEqual([
      {
        placeId: "ChIJsm1",
        main: "SM City Rosales",
        secondary: "Rosales, Pangasinan, Philippines",
      },
    ]);
    expect(sent[0]!.headers["X-Goog-Api-Key"]).toBe("KEY");
    expect(sent[0]!.body).toMatchObject({
      input: "sm city",
      sessionToken: SESSION,
      includedRegionCodes: ["ph"],
      locationBias: { circle: { center: { latitude: 16, longitude: 120.4 }, radius: 50000 } },
    });
    expect(
      await locatePlace("admin1", { placeId: "ChIJsm1", sessionToken: SESSION }, "KEY"),
    ).toEqual({
      lat: 15.89,
      lng: 120.6,
    });
    expect(sent[1]!.headers["X-Goog-FieldMask"]).toBe("location");
  });

  it("checks the input, honours the off switch and reports failures", async () => {
    await expect(
      suggestPlaces("admin1", { input: "sm", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({
      details: { code: "QUERY_INVALID" },
    });
    await expect(
      locatePlace("admin1", { placeId: "../evil", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({ details: { code: "QUERY_INVALID" } });
    failNext = true;
    await expect(
      suggestPlaces("admin1", { input: "dagupan", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({ details: { code: "SEARCH_FAILED" } });
    await db.collection(C.settings).doc("places").set({ enabled: false });
    await expect(
      suggestPlaces("admin1", { input: "dagupan", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({ details: { code: "SEARCH_OFF" } });
    expect(sent).toHaveLength(1);
  });

  it("caps calls per admin and for the project each day", async () => {
    const now = Date.UTC(2026, 10, 14, 4);
    const day = "2026-11-14";
    await db.collection(C.rateLimits).doc(`places__a2__${day}`).set({ count: 150 });
    await expect(
      suggestPlaces("a2", { input: "dagupan", sessionToken: SESSION }, "K", now),
    ).rejects.toMatchObject({ details: { code: "PLACES_USER_LIMIT" } });
    await db.collection(C.rateLimits).doc(`places__${day}`).set({ count: 299 });
    await suggestPlaces("a3", { input: "dagupan", sessionToken: SESSION }, "K", now);
    await expect(
      suggestPlaces("a4", { input: "dagupan", sessionToken: SESSION }, "K", now),
    ).rejects.toMatchObject({ details: { code: "PLACES_PROJECT_LIMIT" } });
  });
});

describe("push registration moves with the person who signs in", () => {
  it("a phone's FID belongs to one account at a time", async () => {
    const tokens = (uid: string) => db.collection(C.users).doc(uid).collection(C.pushTokens);
    expect(await claimPushTokenFor("ana", "fid_phone_1", 1000)).toEqual({ removed: 0 });
    await claimPushTokenFor("ana", "fid_phone_2", 1000);
    expect((await tokens("ana").get()).size).toBe(2);
    expect(await claimPushTokenFor("ben", "fid_phone_1", 2000)).toEqual({ removed: 1 });
    expect((await tokens("ana").get()).docs.map((d) => d.id)).toEqual(["fid_phone_2"]);
    expect(await claimPushTokenFor("ben", "fid_phone_1", 3000)).toEqual({ removed: 0 });
    await expect(claimPushTokenFor("ben", "a/b")).rejects.toMatchObject({
      details: { code: "PAYLOAD_INVALID" },
    });
  });
});
