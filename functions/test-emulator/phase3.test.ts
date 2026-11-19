// Acceptance tests for alerts, weekly calibration and the admin functions. Run
// in-process against the Firestore and Auth emulators with fake SMS and email
// providers; time is passed explicitly, never waited for.
// Run WITHOUT the Functions emulator (npm run test:emulator does this): its real
// Firestore triggers would race these in-process calls on the same database.
import { getAuth } from "firebase-admin/auth";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/https";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { listAdminAudit } from "../src/admin/audit";
import {
  addAllowedDevice,
  adminListDevices,
  assignDevice,
  listDevicesForAdmin,
  removeDevice,
  restoreDevice,
  updateDeviceLabel,
} from "../src/admin/devices";
import { deleteDeviceData, setOwner } from "../src/admin/ownership";
import { purgeExpired } from "../src/admin/purge";
import { createUser, deleteUser, restoreUser, updateUser } from "../src/admin/users";
import { runAlertPass } from "../src/alerts/alertPass";
import { calibrateDevice } from "../src/calibration/calibrate";
import { C, db, liveRef, rtdb, ts } from "../src/lib/db";
import { migrateV2 } from "../src/migration/v2";
import { locatePlace, setPlacesHttp, suggestPlaces } from "../src/maps/places";
import { claimPushTokenFor } from "../src/alerts/pushTokens";
import { setProviders, type Providers } from "../src/lib/providers";
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
  otp = { send: async (_n: string, _m: string, code: string) => code };
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
  owner?: string | null;
  nickname?: string;
  flowStatus?: string | null;
  flowRate?: number;
  abnormalSinceMs?: number | null;
  online?: boolean;
  lastSeenMs?: number | null;
  batteryPercent?: number | null;
  lowVoltageSleep?: boolean;
}

async function seedUser(
  uid = "u1",
  o: { phone?: string; email?: string; status?: "active" | "suspended" } = {},
) {
  await db
    .collection(C.users)
    .doc(uid)
    .set({
      role: "user",
      name: uid,
      phone: o.phone ?? PHONE,
      email: o.email ?? EMAIL,
      status: o.status ?? "active",
      alertPrefs: { push: true, sms: true, email: true },
      deviceCount: 0,
    });
}

async function seedDevice(id: string, o: DeviceSeed = {}) {
  const t = (v: number | null | undefined) => (v === null || v === undefined ? null : ts(v));
  await db
    .collection(C.devices)
    .doc(id)
    .set({
      ownerUid: o.owner === undefined ? "u1" : o.owner,
      nickname: o.nickname ?? `Line ${id}`,
      flowStatus: o.flowStatus === undefined ? "Normal Flow" : o.flowStatus,
      flowRate: o.flowRate ?? 8,
      abnormalSince: t(o.abnormalSinceMs),
      gpsLat: 16.04,
      gpsLng: 120.33,
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2.0,
      statusChangedAt: ts(T0 - H),
      updatedAt: ts(T0),
    });
  await db
    .collection(C.deviceHealth)
    .doc(id)
    .set({
      ownerUid: o.owner === undefined ? "u1" : o.owner,
      online: o.online ?? true,
      lastSeen: t(o.lastSeenMs === undefined ? T0 : o.lastSeenMs),
      batteryPercent: o.batteryPercent === undefined ? 80 : o.batteryPercent,
      batteryVoltage: 7.9,
      batteryFault: false,
      lowVoltageSleep: o.lowVoltageSleep ?? false,
      firmware: "1.0.0",
      rssi: -60,
    });
  // What the monitor and alerts read (D48).
  await liveRef(id).set({
    ownerUid: o.owner === undefined ? "u1" : o.owner,
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

beforeEach(async () => {
  await fetch(`http://${FIRESTORE}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, {
    method: "DELETE",
  });
  await fetch(`http://${AUTH}/emulator/v1/projects/${PROJECT}/accounts`, { method: "DELETE" });
  fake = new Fake();
  setProviders(fake);
  T0 = Math.floor(Date.now() / MIN) * MIN;
  await rtdb.ref().set(null);
  // Admin callables need a live admin record, not only the claim.
  await db.collection(C.admins).doc("admin1").set({ name: "A", status: "active" });
});

afterAll(() => setProviders(null));

describe("alerts", () => {
  it("needs 30 s of Low/No Flow, then sends one SMS and one email", async () => {
    await seedUser();
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 29 * S,
    });
    expect((await runAlertPass(T0)).sent).toHaveLength(0);

    const r = await runAlertPass(T0 + S);
    expect(r.users.u1).toMatchObject({ sms: "sent", email: "sent" });
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
    await seedUser();
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

  it("does not set the lock when every tried channel fails; Low Flow never goes by SMS", async () => {
    await seedUser();
    await seedDevice("D1", { flowStatus: "Low Flow", abnormalSinceMs: T0 - 2 * MIN });
    fake.smsFail = true;
    fake.emailFail = true;
    expect((await runAlertPass(T0)).sent).toHaveLength(0);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(false);

    fake.emailFail = false;
    const r = await runAlertPass(T0 + MIN);
    expect(r.users.u1).toMatchObject({ push: "none", sms: "none", email: "sent" });
    expect(fake.smsSent).toHaveLength(0);
    expect(fake.emailSent).toHaveLength(1);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(true);
  });

  it("re-arms only after 10 min of Normal; a Low/Normal flap sends nothing", async () => {
    await seedUser();
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
    await seedUser();
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
    // Low flow by email only; the one escalation to No Flow also by SMS (D27).
    expect(fake.emailSent.map((m) => m.subject)).toEqual([
      "Hydro Sense alert: Garden Line - Low flow",
      "Hydro Sense alert: Garden Line - No flow",
    ]);
    expect(allSms()).toEqual([
      "HydroSense: No water is flowing at Garden Line. Please check the pipe, valve or pump.",
    ]);
  });

  it("batches 3 failing devices into one SMS and one email within 160 characters", async () => {
    await seedUser();
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
    // "+k more" is unit-tested.
    expect(allSms()[0]!.length).toBeLessThanOrEqual(160);
    expect(allSms()[0]).toMatch(
      /^HydroSense: No water at 3 areas: D1 x+, D2 .+, D3 .+\. Open the app\.$/,
    );
    expect(fake.emailSent[0]!.subject).toBe("Hydro Sense alert: 3 areas need attention");
  });

  it("caps each channel at 10 per day, then sends one digest", async () => {
    await seedUser();
    await db
      .collection(C.alertDaily)
      .doc(`${manilaDateKey(T0)}__u1`)
      .set({ smsCount: 10, emailCount: 3 });
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r1 = await runAlertPass(T0);
    expect(r1.users.u1).toMatchObject({ sms: "digest", email: "sent" });
    expect(allSms()).toEqual(["HydroSense: More alerts today. Open the app for live status."]);

    await seedDevice("D2", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r2 = await runAlertPass(T0 + MIN);
    expect(r2.users.u1).toMatchObject({ sms: "capped", email: "sent" });
    expect(fake.smsSent).toHaveLength(1);
    const cap = await db.collection(C.errorLogs).where("code", "==", "ALERT_CAP_REACHED").get();
    expect(cap.size).toBe(1);
  });

  it("shows Offline at 3 min (no heartbeat reported) and alerts in the same pass (D58)", async () => {
    await seedUser();
    await seedDevice("D1", { nickname: "Garden Line", online: true, lastSeenMs: T0 - 181_000 });
    // The alert pass in the same monitor run finds it already past 2 min.
    const m = await runMonitorPass(T0);
    expect(m.flipped).toEqual(["D1"]);
    expect(fake.smsSent).toHaveLength(0);
    expect(fake.emailSent).toHaveLength(1);
  });

  it("does not alert an offline device before 40 s of silence", async () => {
    await seedUser();
    await seedDevice("D1", { nickname: "Garden Line", online: false, lastSeenMs: T0 - 30_000 });
    await runAlertPass(T0);
    expect(fake.emailSent).toHaveLength(0);
    await runAlertPass(T0 + 10_000);
    expect(fake.emailSent.map((m) => m.subject)).toEqual([
      "Hydro Sense alert: Garden Line - Offline",
    ]);
    expect(fake.smsSent).toHaveLength(0);
  });

  it("uses the battery-empty wording for a device in low-voltage sleep", async () => {
    await seedUser();
    await seedDevice("D1", {
      nickname: "Garden Line",
      online: false,
      lastSeenMs: T0 - 16 * MIN,
      lowVoltageSleep: true,
    });
    await runAlertPass(T0);
    expect(allMail()[0]).toContain("Garden Line is offline because its battery is empty.");
  });

  it("re-arms low battery only above 30 %", async () => {
    await seedUser();
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
  });

  it("sends each alert once when two passes overlap (send lease)", async () => {
    await seedUser();
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    await Promise.all([runAlertPass(T0), runAlertPass(T0)]);
    expect(fake.smsSent).toHaveLength(1);
    expect(fake.emailSent).toHaveLength(1);
  });

  it("keeps phone numbers, emails, nicknames and flow data out of error_logs", async () => {
    await seedUser();
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

  it("sets the weekly formula's cutoffs and calibratedAt (D28)", async () => {
    await seedDevice("D1");
    await seedLogs("D1", 40, 10);
    expect(await calibrateDevice("D1", T0)).toBe("updated");
    const d = await cutoffs("D1");
    expect(d).toMatchObject({ lowFlowCutoff: 1.5, normalFlowCutoff: 5 }); // 0.15 x 10, 0.5 x 10
    expect(d.calibratedAt).toBeInstanceOf(Timestamp);
    expect((await db.collection(C.errorLogs).get()).size).toBe(0);
  });
});

describe("alert channels (D27)", () => {
  const prefs = (p: { push: boolean; sms: boolean; email: boolean }) =>
    db.collection(C.users).doc("u1").update({ alertPrefs: p });
  const token = (fid: string) =>
    db.collection(C.users).doc("u1").collection(C.pushTokens).doc(fid).set({ platform: "android" });

  it("push carries every type with only deviceId or kind in its data", async () => {
    await seedUser();
    await token("fid-1");
    await seedDevice("D1", {
      nickname: "Garden Line",
      flowStatus: "Low Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ push: "sent", sms: "none", email: "sent" });
    expect(fake.pushSent).toEqual([
      {
        fids: ["fid-1"],
        title: "Low water flow at Garden Line",
        body: "Please check the pipe or valve.",
        data: { deviceId: "D1" },
      },
    ]);
  });

  it("a mixed batch: push and email list all, the SMS only the No Flow devices", async () => {
    await seedUser();
    await token("fid-1");
    await seedDevice("D1", {
      nickname: "Garden",
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    await seedDevice("D2", {
      nickname: "Kitchen",
      flowStatus: "Low Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    await seedDevice("D3", { nickname: "Orchard", batteryPercent: 10 });
    await runAlertPass(T0);
    expect(allSms()).toEqual([
      "HydroSense: No water is flowing at Garden. Please check the pipe, valve or pump.",
    ]);
    expect(fake.pushSent[0]).toMatchObject({
      title: "3 areas need attention",
      body: "Garden (no flow), Kitchen (low flow), Orchard (low battery).",
      data: { kind: "batch" },
    });
    expect(fake.emailSent[0]!.subject).toBe("Hydro Sense alert: 3 areas need attention");
  });

  it("a switched-off channel sends nothing and counts nothing", async () => {
    await seedUser();
    await token("fid-1");
    await prefs({ push: false, sms: true, email: false });
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ push: "off", sms: "sent", email: "off" });
    expect(fake.pushSent).toHaveLength(0);
    const day = (
      await db
        .collection(C.alertDaily)
        .doc(`${manilaDateKey(T0)}__u1`)
        .get()
    ).data()!;
    expect(day).toEqual({ smsCount: 1 });
  });

  it("all channels off: nothing is sent, and the lock is still set", async () => {
    await seedUser();
    await prefs({ push: false, sms: false, email: false });
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ push: "off", sms: "off", email: "off" });
    expect(fake.smsSent.length + fake.emailSent.length + fake.pushSent.length).toBe(0);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).get("active")).toBe(true);
  });

  it("deletes installation IDs that FCM reports as gone", async () => {
    await seedUser();
    await token("fid-old");
    await token("fid-new");
    fake.push.send = async (fids, title, body, data) => {
      fake.pushSent.push({ fids, title, body, data });
      return { sent: 1, stale: ["fid-old"] };
    };
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    await runAlertPass(T0);
    const left = await db.collection(C.users).doc("u1").collection(C.pushTokens).get();
    expect(left.docs.map((d) => d.id)).toEqual(["fid-new"]);
  });

  it("push has its own daily cap of 10, then one digest", async () => {
    await seedUser();
    await token("fid-1");
    await db
      .collection(C.alertDaily)
      .doc(`${manilaDateKey(T0)}__u1`)
      .set({ pushCount: 10 });
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r = await runAlertPass(T0);
    expect(r.users.u1!.push).toBe("digest");
    expect(fake.pushSent[0]).toMatchObject({ title: "More alerts today", data: { kind: "batch" } });
  });
});

describe("alerts with several users", () => {
  it("sends each owner one batch and nothing for unassigned, removed or suspended", async () => {
    await seedUser("u1");
    await seedUser("u2", { phone: "639170000002", email: "b@example.com" });
    await seedUser("u3", { phone: "639170000003", email: "c@example.com", status: "suspended" });
    const noFlow = { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN };
    await seedDevice("D1", { ...noFlow, nickname: "A line" });
    await seedDevice("D2", { ...noFlow, nickname: "B line", owner: "u2" });
    await seedDevice("D3", { ...noFlow, owner: null });
    await seedDevice("D4", { ...noFlow, owner: "u3" });
    await seedDevice("D5", { ...noFlow, owner: "u2" });
    await db
      .collection(C.devices)
      .doc("D5")
      .update({ removedAt: ts(T0 - H) });

    const r = await runAlertPass(T0);
    expect(Object.keys(r.users).sort()).toEqual(["u1", "u2"]);
    expect(r.sent.map((i) => i.deviceId).sort()).toEqual(["D1", "D2"]);
    expect(fake.smsSent.map((m) => m.to).sort()).toEqual([PHONE, "639170000002"].sort());
    expect(fake.smsSent.find((m) => m.to === PHONE)!.msg).toContain("A line");
    expect(fake.smsSent.find((m) => m.to === PHONE)!.msg).not.toContain("B line");
  });

  it("counts caps per user, so one user's cap never silences another", async () => {
    await seedUser("u1");
    await seedUser("u2", { phone: "639170000002", email: "b@example.com" });
    await db
      .collection(C.alertDaily)
      .doc(`${manilaDateKey(T0)}__u1`)
      .set({ smsCount: 10, smsDigestSent: true });
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    await seedDevice("D2", {
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 2 * MIN,
      owner: "u2",
    });
    const r = await runAlertPass(T0);
    expect(r.users.u1!.sms).toBe("capped");
    expect(r.users.u2!.sms).toBe("sent");
  });

  it("stops alert SMS at the project ceiling of 50 per day (D30)", async () => {
    await seedUser("u1");
    await db.collection(C.alertDaily).doc(manilaDateKey(T0)).set({ smsCount: 50 });
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    const r = await runAlertPass(T0);
    expect(r.users.u1).toMatchObject({ sms: "capped", email: "sent" });
    expect(fake.smsSent).toHaveLength(0);
    const logs = await db
      .collection(C.errorLogs)
      .where("code", "==", "SMS_PROJECT_CAP_REACHED")
      .get();
    expect(logs.size).toBe(1);
  });

  it("adds each sent alert SMS to the project count", async () => {
    await seedUser("u1");
    await seedDevice("D1", { flowStatus: "No Flow", abnormalSinceMs: T0 - 2 * MIN });
    await runAlertPass(T0);
    const day = await db.collection(C.alertDaily).doc(manilaDateKey(T0)).get();
    expect(day.get("smsCount")).toBe(1);
  });
});

const asAdmin = <T>(data: T, uid = "admin1") =>
  ({ auth: { uid, token: { role: "admin" } }, data }) as unknown as CallableRequest<T>;
const asUser = <T>(data: T) =>
  ({ auth: { uid: "u1", token: { role: "user" } }, data }) as unknown as CallableRequest<T>;
const userDoc = async (uid: string) => (await db.collection(C.users).doc(uid).get()).data()!;
const newUser = (o: Partial<{ name: string; email: string; mobile: string }> = {}) =>
  createUser.run(
    asAdmin({
      name: o.name ?? "Juan Dela Cruz",
      email: o.email ?? "Juan@Example.com",
      mobile: o.mobile ?? "0917 123 4567",
    }),
  );

async function seedAdmins() {
  await db
    .collection(C.admins)
    .doc("admin1")
    .set({ name: "A", email: "admin1@example.com", status: "active" });
  await db
    .collection(C.admins)
    .doc("admin2")
    .set({ name: "B", email: "admin2@example.com", status: "active" });
}

describe("user management (D20, D22, D42)", () => {
  it("creates a user with no password, the user role, defaults and a phone index entry", async () => {
    const { uid } = await newUser();
    const auth = await getAuth().getUser(uid);
    expect(auth.customClaims).toEqual({ role: "user" });
    expect(auth.passwordHash).toBeUndefined();
    expect(await userDoc(uid)).toMatchObject({
      role: "user",
      name: "Juan Dela Cruz",
      email: "juan@example.com",
      phone: PHONE,
      passwordSet: false,
      deviceCount: 0,
      alertPrefs: { push: true, sms: true, email: false },
      status: "active",
    });
    expect((await db.collection(C.phoneIndex).doc(PHONE).get()).get("uid")).toBe(uid);
  });

  it("refuses a duplicate email or mobile and leaves no half-made account", async () => {
    await newUser();
    await expect(newUser({ mobile: "09170000000" })).rejects.toMatchObject({
      details: { code: "EMAIL_IN_USE" },
    });
    await expect(newUser({ email: "other@example.com" })).rejects.toMatchObject({
      details: { code: "PHONE_IN_USE" },
    });
    expect((await getAuth().listUsers()).users).toHaveLength(1);
  });

  it("validates input and refuses non-admins", async () => {
    await expect(newUser({ mobile: "12345" })).rejects.toMatchObject({
      details: { code: "PHONE_INVALID" },
    });
    await expect(newUser({ name: "  " })).rejects.toMatchObject({
      details: { code: "NAME_INVALID" },
    });
    await expect(
      createUser.run(asUser({ name: "x", email: "x@example.com", mobile: "09171234567" })),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });

  it("updates name, email and mobile, keeping Auth and the phone index in step", async () => {
    const { uid } = await newUser();
    await newUser({ email: "b@example.com", mobile: "09170000002" });
    await expect(updateUser.run(asAdmin({ uid, mobile: "09170000002" }))).rejects.toMatchObject({
      details: { code: "PHONE_IN_USE" },
    });
    await expect(updateUser.run(asAdmin({ uid, email: "b@example.com" }))).rejects.toMatchObject({
      details: { code: "EMAIL_IN_USE" },
    });

    await updateUser.run(
      asAdmin({ uid, name: "Juan D.", email: "new@example.com", mobile: "09179999999" }),
    );
    expect(await userDoc(uid)).toMatchObject({
      name: "Juan D.",
      email: "new@example.com",
      phone: "639179999999",
    });
    expect((await getAuth().getUser(uid)).email).toBe("new@example.com");
    expect((await db.collection(C.phoneIndex).doc(PHONE).get()).exists).toBe(false);
    expect((await db.collection(C.phoneIndex).doc("639179999999").get()).get("uid")).toBe(uid);
  });

  it("deleteUser needs the typed name, suspends, logs and emails the other admins", async () => {
    await seedAdmins();
    const { uid } = await newUser();
    await expect(deleteUser.run(asAdmin({ uid, confirmName: "Juan" }))).rejects.toMatchObject({
      details: { code: "CONFIRM_MISMATCH" },
    });

    await deleteUser.run(asAdmin({ uid, confirmName: " juan dela cruz " }));
    expect((await getAuth().getUser(uid)).disabled).toBe(true);
    const u = await userDoc(uid);
    expect(u.status).toBe("suspended");
    expect(u.purgeAfter.toMillis() - u.suspendedAt.toMillis()).toBe(30 * 24 * H);

    const log = await db.collection(C.adminAudit).get();
    expect(log.docs.map((d) => d.data())).toMatchObject([
      { action: "user_deleted", adminUid: "admin1", targetId: uid, targetName: "Juan Dela Cruz" },
    ]);
    expect(fake.emailSent.map((e) => e.to)).toEqual(["admin2@example.com"]);
  });

  it("a suspended user gets no alerts; restoreUser brings everything back", async () => {
    const { uid } = await newUser();
    await seedDevice("D1", {
      owner: uid,
      flowStatus: "No Flow",
      abnormalSinceMs: T0 - 2 * MIN,
    });
    await deleteUser.run(asAdmin({ uid, confirmName: "Juan Dela Cruz" }));
    expect((await runAlertPass(T0)).sent).toHaveLength(0);
    expect((await db.collection(C.devices).doc("D1").get()).get("ownerUid")).toBe(uid);

    await restoreUser.run(asAdmin({ uid }));
    expect((await getAuth().getUser(uid)).disabled).toBe(false);
    expect(await userDoc(uid)).toMatchObject({ status: "active", purgeAfter: null });
    expect((await runAlertPass(T0 + MIN)).sent).toHaveLength(1);
    const actions = (await db.collection(C.adminAudit).get()).docs.map((d) => d.get("action"));
    expect(actions.sort()).toEqual(["user_deleted", "user_restored"]);
  });

  it("purges a suspended user after 30 days: devices unassigned with history deleted", async () => {
    const { uid } = await newUser();
    await seedDevice("D1", { owner: uid });
    await db
      .collection(C.devices)
      .doc("D1")
      .collection(C.flowLogs)
      .add({ ts: ts(T0) });
    await db.collection(C.pipelines).doc(uid).set({ name: "P", branches: [] });
    await deleteUser.run(asAdmin({ uid, confirmName: "Juan Dela Cruz" }));
    const purgeAt = (await userDoc(uid)).purgeAfter.toMillis() as number;

    expect((await purgeExpired(purgeAt - MIN)).users).toEqual([]);
    expect((await purgeExpired(purgeAt + MIN)).users).toEqual([uid]);
    expect((await db.collection(C.users).doc(uid).get()).exists).toBe(false);
    expect((await db.collection(C.phoneIndex).doc(PHONE).get()).exists).toBe(false);
    expect((await db.collection(C.pipelines).doc(uid).get()).exists).toBe(false);
    await expect(getAuth().getUser(uid)).rejects.toMatchObject({ code: "auth/user-not-found" });
    expect((await db.collection(C.devices).doc("D1").get()).get("ownerUid")).toBeNull();
    expect((await db.collection(C.devices).doc("D1").collection(C.flowLogs).get()).size).toBe(0);
  });
});

describe("device admin (D20, D24, D32, D41, D42)", () => {
  const listed = async (id: string, label?: string) =>
    db
      .collection(C.allowedDevices)
      .doc(id)
      .set({ addedAt: ts(T0), ...(label ? { label } : {}) });

  it("reassigning wipes history, nickname, pin, cutoffs and the old pipeline entry first", async () => {
    await seedUser("u1");
    await seedUser("u2", { phone: "639170000002" });
    await listed("D1", "Unit 1");
    await seedDevice("D1", { nickname: "Garden Line" });
    const d1 = db.collection(C.devices).doc("D1");
    await d1.update({
      manualLat: 16.1,
      manualLng: 120.4,
      lowFlowCutoff: 1.5,
      userNormalCutoff: 6,
      calibratedAt: ts(T0),
    });
    await d1.collection(C.flowLogs).add({ ts: ts(T0), flowStatus: "Normal Flow" });
    await db.collection(C.alertState).doc("D1__flow").set({ active: true });
    await db.collection(C.problems).add({ ownerUid: "u1", deviceId: "D1", type: "no_flow" });
    await liveRef("D1").child("ownerUid").set("u1");
    await db
      .collection(C.pipelines)
      .doc("u1")
      .set({
        name: "P",
        branches: [{ id: "b1", deviceIds: ["D0", "D1", "D2"] }],
      });

    const out = await setOwner("D1", "u2");
    expect(out).toEqual({ kind: "changed", from: "u1", to: "u2", created: false });
    const after = (await d1.get()).data()!;
    expect(after).toMatchObject({
      ownerUid: "u2",
      nickname: "Device D1",
      manualLat: null,
      manualLng: null,
      lowFlowCutoff: 0.2,
      normalFlowCutoff: 2.0,
      userNormalCutoff: null,
      calibratedAt: null,
    });
    expect((await db.collection(C.deviceHealth).doc("D1").get()).get("ownerUid")).toBe("u2");
    expect((await d1.collection(C.flowLogs).get()).size).toBe(0);
    expect((await db.collection(C.alertState).doc("D1__flow").get()).exists).toBe(false);
    // Problems go with the history (D49); the live node follows the new owner (D48).
    expect((await db.collection(C.problems).where("deviceId", "==", "D1").get()).size).toBe(0);
    expect((await liveRef("D1").child("ownerUid").get()).val()).toBe("u2");
    const branches = (await db.collection(C.pipelines).doc("u1").get()).get("branches");
    expect(branches[0].deviceIds).toEqual(["D0", "D2"]);
  });

  it("assigning an unregistered ID creates its records with the owner set (D41)", async () => {
    await seedUser("u1");
    await listed("A1B2C3D4E5F6");
    const r = await assignDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", uid: "u1" }));
    expect(r).toMatchObject({ changed: true, created: true });
    expect((await db.collection(C.devices).doc("A1B2C3D4E5F6").get()).data()).toMatchObject({
      ownerUid: "u1",
      nickname: "Device E5F6",
      flowStatus: null,
    });
    expect((await db.collection(C.deviceHealth).doc("A1B2C3D4E5F6").get()).data()).toMatchObject({
      ownerUid: "u1",
      online: false,
      registeredAt: null,
    });
  });

  it("refuses an unlisted device, a missing user and a suspended user", async () => {
    await seedUser("u1", { status: "suspended" });
    await expect(
      assignDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", uid: "u1" })),
    ).rejects.toMatchObject({ details: { code: "DEVICE_NOT_FOUND" } });
    await listed("A1B2C3D4E5F6");
    await expect(
      assignDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", uid: "nobody" })),
    ).rejects.toMatchObject({ details: { code: "USER_NOT_FOUND" } });
    await expect(
      assignDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", uid: "u1" })),
    ).rejects.toMatchObject({ details: { code: "USER_SUSPENDED" } });
  });

  it("logs a reassignment but not a first assignment", async () => {
    await seedUser("u1");
    await seedUser("u2", { phone: "639170000002" });
    await listed("A1B2C3D4E5F6", "Unit 1");
    await assignDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", uid: "u1" }));
    expect((await db.collection(C.adminAudit).get()).size).toBe(0);
    await assignDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", uid: "u2" }));
    const log = (await db.collection(C.adminAudit).get()).docs.map((d) => d.data());
    expect(log).toMatchObject([{ action: "device_reassigned", targetName: "Unit 1" }]);
  });

  it("labels: set, change, clear; 1 to 24 characters", async () => {
    await addAllowedDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", label: " Unit 1 " }));
    const entry = db.collection(C.allowedDevices).doc("A1B2C3D4E5F6");
    expect((await entry.get()).get("label")).toBe("Unit 1");
    await updateDeviceLabel.run(asAdmin({ deviceId: "A1B2C3D4E5F6", label: "Pump house" }));
    expect((await entry.get()).get("label")).toBe("Pump house");
    await updateDeviceLabel.run(asAdmin({ deviceId: "A1B2C3D4E5F6", label: null }));
    expect((await entry.get()).get("label")).toBeUndefined();
    await expect(
      updateDeviceLabel.run(asAdmin({ deviceId: "A1B2C3D4E5F6", label: "x".repeat(25) })),
    ).rejects.toMatchObject({ details: { code: "LABEL_INVALID" } });
    await expect(addAllowedDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6" }))).rejects.toMatchObject(
      { details: { code: "DEVICE_EXISTS" } },
    );
  });

  it("removeDevice needs the typed label; the data stays until the purge", async () => {
    await seedAdmins();
    await seedUser("u1");
    await listed("A1B2C3D4E5F6", "Unit 1");
    await setOwner("A1B2C3D4E5F6", "u1");
    await expect(
      removeDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", confirmLabel: "A1B2C3D4E5F6" })),
    ).rejects.toMatchObject({ details: { code: "CONFIRM_MISMATCH" } });
    const { purgeAfterMs } = await removeDevice.run(
      asAdmin({ deviceId: "A1B2C3D4E5F6", confirmLabel: "unit 1" }),
    );
    const dev = db.collection(C.devices).doc("A1B2C3D4E5F6");
    expect((await dev.get()).get("ownerUid")).toBe("u1");
    expect(fake.emailSent.map((e) => e.to)).toEqual(["admin2@example.com"]);

    const rows = await listDevicesForAdmin();
    expect(rows).toMatchObject([
      { id: "A1B2C3D4E5F6", label: "Unit 1", removedAtMs: expect.any(Number) },
    ]);

    expect((await purgeExpired(purgeAfterMs - MIN)).devices).toEqual([]);
    expect((await purgeExpired(purgeAfterMs + MIN)).devices).toEqual(["A1B2C3D4E5F6"]);
    expect((await dev.get()).exists).toBe(false);
    expect((await db.collection(C.deviceHealth).doc("A1B2C3D4E5F6").get()).exists).toBe(false);
  });

  it("restoreDevice puts the label back and refuses after the window", async () => {
    await listed("A1B2C3D4E5F6", "Unit 1");
    await seedDevice("A1B2C3D4E5F6", { owner: null });
    await removeDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", confirmLabel: "Unit 1" }));
    await restoreDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6" }));
    expect((await db.collection(C.allowedDevices).doc("A1B2C3D4E5F6").get()).get("label")).toBe(
      "Unit 1",
    );

    await removeDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6", confirmLabel: "Unit 1" }));
    await db
      .collection(C.devices)
      .doc("A1B2C3D4E5F6")
      .update({ purgeAfter: ts(Date.now() - MIN) });
    await expect(restoreDevice.run(asAdmin({ deviceId: "A1B2C3D4E5F6" }))).rejects.toMatchObject({
      details: { code: "RESTORE_EXPIRED" },
    });
  });

  it("adminListDevices returns only the D24 fields", async () => {
    await seedUser("u1");
    await listed("A1B2C3D4E5F6", "Unit 1");
    await listed("B1B2C3D4E5F6");
    await seedDevice("A1B2C3D4E5F6", { nickname: "Secret Garden", batteryPercent: 15 });
    await db
      .collection(C.deviceHealth)
      .doc("A1B2C3D4E5F6")
      .update({ registeredAt: ts(T0 - H) });
    const { rows: devices } = await adminListDevices.run(asAdmin({}));
    const byId = Object.fromEntries(devices.map((d) => [d.id, d]));
    expect(byId.A1B2C3D4E5F6).toEqual({
      id: "A1B2C3D4E5F6",
      label: "Unit 1",
      ownerUid: "u1",
      ownerName: "u1",
      registered: true,
      online: true,
      lastSeenMs: T0,
      removedAtMs: null,
      purgeAfterMs: null,
    });
    expect(byId.B1B2C3D4E5F6).toMatchObject({ registered: false, online: false, ownerUid: null });
    const all = JSON.stringify(devices);
    for (const hidden of ["Secret Garden", "No Flow", "Normal Flow", "16.04", "battery"]) {
      expect(all).not.toContain(hidden);
    }
  });

  it("listAdminAudit returns the newest entries first", async () => {
    const { uid } = await newUser();
    await deleteUser.run(asAdmin({ uid, confirmName: "Juan Dela Cruz" }));
    await restoreUser.run(asAdmin({ uid }));
    const { entries } = await listAdminAudit.run(asAdmin({}));
    expect(entries.map((e) => e.action)).toEqual(["user_restored", "user_deleted"]);
    await expect(listAdminAudit.run(asUser({}))).rejects.toMatchObject({
      code: "permission-denied",
    });
  });
});

describe("v1 -> v2 migration", () => {
  async function seedV1() {
    const auth = getAuth();
    await auth.createUser({ uid: "c1", email: "client@example.com", password: "secret123" });
    await auth.setCustomUserClaims("c1", { role: "client" });
    await auth.createUser({ uid: "a1", email: "Admin@Example.com", displayName: "Ad" });
    await auth.setCustomUserClaims("a1", { role: "admin" });
    await db
      .collection(C.users)
      .doc("c1")
      .set({
        role: "client",
        email: "client@example.com",
        phone: PHONE,
        displayName: "Juan",
        mustChangePassword: false,
        lastCalibrateAt: ts(T0),
        createdAt: ts(T0 - H),
      });
    await db.collection("config").doc("system").set({ clientUid: "c1" });
    await db.collection(C.devices).doc("D1").set({
      ownerUid: "c1",
      nickname: "Garden Line",
      lat: 16.04,
      lng: 120.33,
      pausedUntil: null,
    });
    await db.collection(C.deviceHealth).doc("D1").set({ ownerUid: "c1", lastBatteryLogAt: null });
  }

  it("dry run lists every change and changes nothing", async () => {
    await seedV1();
    const r = await migrateV2({ apply: false });
    expect(r.steps.map((s) => s.target)).toEqual(
      expect.arrayContaining([
        "admins/a1",
        "auth/c1",
        "users/c1",
        `phone_index/${PHONE}`,
        "devices/D1",
        "device_health/D1",
        "config/system",
      ]),
    );
    expect((await getAuth().getUser("c1")).customClaims).toEqual({ role: "client" });
    expect((await db.collection("config").doc("system").get()).exists).toBe(true);
  });

  it("applies the v2 shape and a second run changes nothing", async () => {
    await seedV1();
    const r = await migrateV2({ apply: true, nowMs: T0 });
    expect(r.problems).toEqual([]);

    expect((await getAuth().getUser("c1")).customClaims).toEqual({ role: "user" });
    const u = (await db.collection(C.users).doc("c1").get()).data()!;
    expect(u).toMatchObject({
      role: "user",
      name: "Juan",
      phone: PHONE,
      passwordSet: true,
      deviceCount: 1,
      alertPrefs: { push: true, sms: true, email: false },
      status: "active",
    });
    for (const gone of ["displayName", "mustChangePassword", "lastCalibrateAt"]) {
      expect(u).not.toHaveProperty(gone);
    }
    expect((await db.collection(C.phoneIndex).doc(PHONE).get()).get("uid")).toBe("c1");
    expect((await db.collection(C.admins).doc("a1").get()).data()).toMatchObject({
      email: "admin@example.com",
      status: "active",
    });
    const d = (await db.collection(C.devices).doc("D1").get()).data()!;
    expect(d).toMatchObject({ gpsLat: 16.04, gpsLng: 120.33, manualLat: null, manualLng: null });
    for (const gone of ["lat", "lng", "pausedUntil"]) expect(d).not.toHaveProperty(gone);
    expect((await db.collection(C.deviceHealth).doc("D1").get()).data()).not.toHaveProperty(
      "lastBatteryLogAt",
    );
    expect((await db.collection("config").doc("system").get()).exists).toBe(false);

    expect((await migrateV2({ apply: true, nowMs: T0 })).steps).toEqual([]);
  });

  it("the migrated user gets alerts again", async () => {
    await seedV1();
    await migrateV2({ apply: true, nowMs: T0 });
    await liveRef("D1").set({
      ownerUid: "c1",
      online: true,
      lastSeen: T0,
      flowStatus: "No Flow",
      abnormalSince: T0 - 2 * MIN,
    });
    const r = await runAlertPass(T0);
    // The migrated account gets the defaults (D27): email starts off.
    expect(r.users.c1).toMatchObject({ sms: "sent", email: "off" });
  });
});

describe("deviceCount (TODO(human) in admin/ownership.ts)", () => {
  const count = async (uid: string) =>
    (await db.collection(C.users).doc(uid).get()).get("deviceCount");

  it("follows every assignment, reassignment and unassignment", async () => {
    await seedUser("u1");
    await seedUser("u2", { phone: "639170000002" });
    await setOwner("A1B2C3D4E5F1", "u1"); // never registered: records created
    await setOwner("A1B2C3D4E5F2", "u1");
    expect([await count("u1"), await count("u2")]).toEqual([2, 0]);

    await setOwner("A1B2C3D4E5F2", "u2");
    expect([await count("u1"), await count("u2")]).toEqual([1, 1]);

    await setOwner("A1B2C3D4E5F1", null);
    await setOwner("A1B2C3D4E5F2", "u2"); // unchanged: no double count
    expect([await count("u1"), await count("u2")]).toEqual([0, 1]);
  });

  it("drops a purged device from its owner's count", async () => {
    await seedUser("u1");
    await setOwner("A1B2C3D4E5F1", "u1");
    await setOwner("A1B2C3D4E5F2", "u1");
    await deleteDeviceData("A1B2C3D4E5F1");
    expect(await count("u1")).toBe(1);
  });
});

describe("place search (Google Places, D46)", () => {
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
      "u1",
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
    expect(sent[0].headers["X-Goog-Api-Key"]).toBe("KEY");
    expect(sent[0].body).toMatchObject({
      input: "sm city",
      sessionToken: SESSION,
      includedRegionCodes: ["ph"],
      locationBias: { circle: { center: { latitude: 16, longitude: 120.4 }, radius: 50000 } },
    });

    expect(await locatePlace("u1", { placeId: "ChIJsm1", sessionToken: SESSION }, "KEY")).toEqual({
      lat: 15.89,
      lng: 120.6,
    });
    // Only the location field (Essentials), and the same session closes it.
    expect(sent[1].url).toBe(
      `https://places.googleapis.com/v1/places/ChIJsm1?sessionToken=${SESSION}`,
    );
    expect(sent[1].headers["X-Goog-FieldMask"]).toBe("location");
  });

  it("checks the input, honours the off switch and reports failures", async () => {
    await expect(
      suggestPlaces("u1", { input: "sm", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({
      details: { code: "QUERY_INVALID" },
    });
    await expect(
      suggestPlaces("u1", { input: "sm city", sessionToken: "x" }, "K"),
    ).rejects.toMatchObject({
      details: { code: "QUERY_INVALID" },
    });
    await expect(
      locatePlace("u1", { placeId: "../evil", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({ details: { code: "QUERY_INVALID" } });

    failNext = true;
    await expect(
      suggestPlaces("u1", { input: "dagupan", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({
      details: { code: "SEARCH_FAILED" },
    });

    await db.collection(C.settings).doc("places").set({ enabled: false });
    await expect(
      suggestPlaces("u1", { input: "dagupan", sessionToken: SESSION }, "K"),
    ).rejects.toMatchObject({
      details: { code: "SEARCH_OFF" },
    });
    expect(sent).toHaveLength(1);
  });

  it("caps calls per user and for the project each day", async () => {
    const now = Date.UTC(2026, 10, 14, 4);
    const day = "2026-11-14";
    await db.collection(C.rateLimits).doc(`places__u2__${day}`).set({ count: 150 });
    await expect(
      suggestPlaces("u2", { input: "dagupan", sessionToken: SESSION }, "K", now),
    ).rejects.toMatchObject({ details: { code: "PLACES_USER_LIMIT" } });

    await db.collection(C.rateLimits).doc(`places__${day}`).set({ count: 299 });
    await suggestPlaces("u3", { input: "dagupan", sessionToken: SESSION }, "K", now);
    await expect(
      suggestPlaces("u4", { input: "dagupan", sessionToken: SESSION }, "K", now),
    ).rejects.toMatchObject({ details: { code: "PLACES_PROJECT_LIMIT" } });
    expect((await db.collection(C.rateLimits).doc(`places__u3__${day}`).get()).get("count")).toBe(
      1,
    );
  });
});

describe("push registration moves with the person who signs in (D45)", () => {
  it("a phone's FID belongs to one account at a time", async () => {
    const tokens = (uid: string) => db.collection(C.users).doc(uid).collection(C.pushTokens);
    expect(await claimPushTokenFor("ana", "fid_phone_1", 1000)).toEqual({ removed: 0 });
    await claimPushTokenFor("ana", "fid_phone_2", 1000);
    expect((await tokens("ana").get()).size).toBe(2);

    // Someone else signs in on phone 1.
    expect(await claimPushTokenFor("ben", "fid_phone_1", 2000)).toEqual({ removed: 1 });
    expect((await tokens("ana").get()).docs.map((d) => d.id)).toEqual(["fid_phone_2"]);
    expect((await tokens("ben").doc("fid_phone_1").get()).data()).toMatchObject({
      platform: "android",
      fid: "fid_phone_1",
    });
    // Signing in again on your own phone removes nothing.
    expect(await claimPushTokenFor("ben", "fid_phone_1", 3000)).toEqual({ removed: 0 });
    await expect(claimPushTokenFor("ben", "a/b")).rejects.toMatchObject({
      details: { code: "PAYLOAD_INVALID" },
    });
  });
});
