// Alert wording, used exactly as docs/UI_UX_SPEC.md section 6 gives it.
import { SMS_MAX_CHARS } from "../config";
import { formatManila } from "./time";

export type AlertType = "flow_low" | "flow_none" | "battery_low" | "offline";

export interface AlertItem {
  deviceId: string;
  nickname: string;
  type: AlertType;
  reminder: boolean;
  batteryPercent: number | null;
  /** Offline because the device entered low-voltage sleep. */
  batteryEmpty: boolean;
  sinceMs: number;
}

const ISSUE: Record<AlertType, string> = {
  flow_none: "no flow",
  flow_low: "low flow",
  offline: "offline",
  battery_low: "low battery",
};

const TITLE: Record<AlertType, string> = {
  flow_none: "No flow",
  flow_low: "Low flow",
  offline: "Offline",
  battery_low: "Low battery",
};

const SEVERITY: Record<AlertType, number> = { flow_none: 0, flow_low: 1, offline: 2, battery_low: 3 };

const pct = (i: AlertItem) => `${i.batteryPercent ?? 0}%`;

function singleSms(i: AlertItem): string {
  const n = i.nickname;
  if (i.reminder) {
    switch (i.type) {
      case "flow_none":
        return `Hydro Sense: Reminder: still no water at ${n}. Please check the pipe, valve or pump.`;
      case "flow_low":
        return `Hydro Sense: Reminder: ${n} still has low water flow. Please check the pipe or valve.`;
      case "battery_low":
        return `Hydro Sense: Reminder: ${n} battery is still low (${pct(i)}). Please check its solar panel.`;
      case "offline":
        return `Hydro Sense: Reminder: ${n} is still offline. Please check its power and Wi-Fi.`;
    }
  }
  switch (i.type) {
    case "flow_none":
      return `Hydro Sense: No water is flowing at ${n}. Please check the pipe, valve or pump.`;
    case "flow_low":
      return `Hydro Sense: ${n} has low water flow. Please check the pipe or valve.`;
    case "battery_low":
      return `Hydro Sense: ${n} battery is low (${pct(i)}). Please check its solar panel.`;
    case "offline":
      return i.batteryEmpty
        ? `Hydro Sense: ${n} is offline because its battery is empty. Please check its solar panel.`
        : `Hydro Sense: ${n} is offline. Please check its power and Wi-Fi.`;
  }
}

/** Worst issue first, then nickname; one entry per device (its worst issue). */
export function byDevice(items: readonly AlertItem[]): AlertItem[] {
  const worst = new Map<string, AlertItem>();
  for (const i of items) {
    const cur = worst.get(i.deviceId);
    if (!cur || SEVERITY[i.type] < SEVERITY[cur.type]) worst.set(i.deviceId, i);
  }
  return [...worst.values()].sort(
    (a, b) => SEVERITY[a.type] - SEVERITY[b.type] || a.nickname.localeCompare(b.nickname),
  );
}

/**
 * One SMS for everything due in a pass; never longer than SMS_MAX_CHARS. Alert SMS
 * carry only No Flow (D27), so a batch reads "No water at {n} areas: ..." (UI spec 7).
 */
export function buildSms(items: readonly AlertItem[]): string {
  const list = byDevice(items);
  if (list.length === 1) return singleSms(list[0]!);
  const noFlowOnly = list.every((i) => i.type === "flow_none");
  const head = noFlowOnly
    ? `Hydro Sense: No water at ${list.length} areas: `
    : `Hydro Sense: ${list.length} areas need attention: `;
  const name = (i: AlertItem) => (noFlowOnly ? i.nickname : `${i.nickname} (${ISSUE[i.type]})`);
  for (let k = list.length; k >= 1; k--) {
    const shown = list.slice(0, k).map(name).join(", ");
    const more = k < list.length ? `, +${list.length - k} more` : "";
    const text = `${head}${shown}${more}. Open the app.`;
    if (text.length <= SMS_MAX_CHARS) return text;
  }
  return `Hydro Sense: ${list.length} areas need attention. Open the app.`;
}

export interface PushMessage {
  title: string;
  body: string;
  /** Only what the app needs to open the right screen (D37, section 7 rule 14). */
  data: { deviceId: string } | { kind: "batch" };
}

function singlePush(i: AlertItem): Omit<PushMessage, "data"> {
  const n = i.nickname;
  const still = i.reminder ? "Still: " : "";
  switch (i.type) {
    case "flow_none":
      return { title: `${still}No water at ${n}`, body: "Please check the pipe, valve or pump." };
    case "flow_low":
      return { title: `${still}Low water flow at ${n}`, body: "Please check the pipe or valve." };
    case "battery_low":
      return { title: `${still}${n} battery is low (${pct(i)})`, body: "Please check its solar panel." };
    case "offline":
      return i.batteryEmpty
        ? { title: `${still}${n} is offline: battery empty`, body: "Please check its solar panel." }
        : { title: `${still}${n} is offline`, body: "Please check its power and Wi-Fi." };
  }
}

/** Push names at most this many devices, then "+k more". */
const PUSH_NAMES_MAX = 3;

/** One push for everything due in a pass (docs/UI_UX_SPEC.md section 7). */
export function buildPush(items: readonly AlertItem[]): PushMessage {
  const list = byDevice(items);
  if (list.length === 1) return { ...singlePush(list[0]!), data: { deviceId: list[0]!.deviceId } };
  const shown = list
    .slice(0, PUSH_NAMES_MAX)
    .map((i) => `${i.nickname} (${ISSUE[i.type]})`)
    .join(", ");
  const more = list.length > PUSH_NAMES_MAX ? `, +${list.length - PUSH_NAMES_MAX} more` : "";
  return {
    title: `${list.length} areas need attention`,
    body: `${shown}${more}.`,
    data: { kind: "batch" },
  };
}

export const DIGEST_PUSH: PushMessage = {
  title: "More alerts today",
  body: "Open the app for live status.",
  data: { kind: "batch" },
};

export const DIGEST_SMS = "Hydro Sense: More alerts today. Open the app for live status.";

function sentence(i: AlertItem): string {
  const n = i.nickname;
  switch (i.type) {
    case "flow_none":
      return `No water is flowing at ${n}.`;
    case "flow_low":
      return `${n} has low water flow.`;
    case "battery_low":
      return `${n} battery is low (${pct(i)}).`;
    case "offline":
      return i.batteryEmpty ? `${n} is offline because its battery is empty.` : `${n} is offline.`;
  }
}

const WHAT_TO_CHECK = [
  "What to check:",
  "- The valve is open",
  "- The pipe or filter is not blocked",
  "- The pump is running",
  "- The device has power and Wi-Fi",
].join("\n");

export function buildEmail(items: readonly AlertItem[]): { subject: string; text: string } {
  const list = byDevice(items);
  const reminder = list.every((i) => i.reminder);
  const prefix = reminder ? "Reminder: " : "";
  const subject =
    list.length === 1
      ? `${prefix}Hydro Sense alert: ${list[0]!.nickname} - ${TITLE[list[0]!.type]}`
      : `${prefix}Hydro Sense alert: ${list.length} areas need attention`;
  const lines = list.map((i) => `${sentence(i)} Since ${formatManila(i.sinceMs)}.`);
  const text = [
    ...(reminder ? ["Reminder:"] : []),
    ...lines,
    "",
    WHAT_TO_CHECK,
    "",
    "Open the Hydro Sense app for live status.",
  ].join("\n");
  return { subject, text };
}

export const DIGEST_EMAIL = {
  subject: "Hydro Sense alert: more alerts today",
  text: "Hydro Sense has sent today's maximum number of alerts.\n\nOpen the Hydro Sense app for live status.",
};
