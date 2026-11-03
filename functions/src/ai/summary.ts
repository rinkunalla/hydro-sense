import { onDocumentUpdated } from "firebase-functions/firestore";
import { HttpsError, onCall } from "firebase-functions/https";
import { AI_COOLDOWN_S, AI_SUMMARY_MAX_CHARS } from "../config";
import { requireClient } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { MODEL_SECRETS, providers } from "../lib/providers";

const SOURCE = "generateClientFlowSummary";
const SUMMARY = () => db.collection(C.aiInsights).doc("client_summary");

type LineStatus = "Normal Flow" | "Low Flow" | "No Flow" | "Offline" | "Waiting";

interface Line {
  id: string;
  nickname: string;
  status: LineStatus;
  flowRate: number | null;
}

export type SummaryResult =
  | { status: "updated"; text: string }
  | { status: "fallback"; text: string } // model failed, no earlier text: plain wording written
  | { status: "kept" } // model failed: earlier text kept
  | { status: "cooldown"; retryAfterSeconds: number }
  | { status: "no_client" };

async function currentLines(clientUid: string): Promise<Line[]> {
  const [devices, health] = await Promise.all([
    db.collection(C.devices).where("ownerUid", "==", clientUid).get(),
    db.collection(C.deviceHealth).where("ownerUid", "==", clientUid).get(),
  ]);
  const h = new Map(health.docs.map((d) => [d.id, d.data()]));
  return devices.docs
    .map((d) => {
      const hd = h.get(d.id);
      const offline = hd?.online !== true && ms(hd?.lastSeen) !== null;
      const flow = (d.get("flowStatus") as LineStatus | null) ?? null;
      return {
        id: d.id,
        nickname: d.get("nickname") as string,
        status: offline ? "Offline" : (flow ?? "Waiting"),
        flowRate: (d.get("flowRate") as number | null) ?? null,
      } satisfies Line;
    })
    .sort((a, b) => a.nickname.localeCompare(b.nickname));
}

const WORD: Record<LineStatus, string> = {
  "Normal Flow": "normal flow",
  "Low Flow": "low flow",
  "No Flow": "no flow",
  Offline: "offline",
  Waiting: "waiting for its first reading",
};

/** Plain wording used when the model is unavailable (matches the summary banner). */
export function fallbackSummary(lines: readonly Line[]): string {
  if (lines.length === 0) return "No devices are set up yet.";
  const problems = lines.filter((l) => l.status !== "Normal Flow" && l.status !== "Waiting");
  if (problems.length === 0) return `All ${lines.length} areas have normal flow.`;
  const named = problems.map((l) => `${l.nickname} (${WORD[l.status]})`).join(", ");
  const n = problems.length;
  return `${n} ${n === 1 ? "area needs" : "areas need"} attention: ${named}. Check the valve, pipe, pump or device power.`;
}

const SYSTEM =
  "You write the status summary in a home water-flow monitoring app. Reply in exactly two short " +
  "sentences of plain language, no jargon, no lists. The first sentence says whether water is " +
  "flowing properly to every area and names any area with a problem. The second says what to " +
  "check (valve, pipe or filter, pump, or device power and Wi-Fi), or that no action is needed. " +
  "Use only the data given.";

const prompt = (lines: readonly Line[]) =>
  "Areas:\n" +
  lines
    .map(
      (l) =>
        `- ${l.nickname}: ${WORD[l.status]}` +
        (l.flowRate !== null && l.status !== "Offline" ? ` (${l.flowRate.toFixed(1)} L/min)` : ""),
    )
    .join("\n");

const isUrgent = (s: string | undefined) => s === "No Flow" || s === "Offline";

/**
 * One summary per AI_COOLDOWN_S, except when a device newly entered No Flow or Offline
 * since the last summary. The cooldown is claimed in a transaction so parallel calls
 * reach the model once (CLAUDE.md D18).
 */
export async function refreshSummary(nowMs = Date.now()): Promise<SummaryResult> {
  const system = await db.collection(C.config).doc("system").get();
  const clientUid = system.get("clientUid") as string | undefined;
  if (!clientUid) return { status: "no_client" };
  const lines = await currentLines(clientUid);
  const statuses = Object.fromEntries(lines.map((l) => [l.id, l.status]));

  const claim = await db.runTransaction(async (tx) => {
    const snap = await tx.get(SUMMARY());
    const lastAttemptMs = ms(snap.get("lastAttemptAt"));
    const prev = (snap.get("statuses") as Record<string, string> | undefined) ?? {};
    const urgent = lines.some((l) => isUrgent(l.status) && prev[l.id] !== l.status);
    const waitMs = lastAttemptMs === null ? 0 : lastAttemptMs + AI_COOLDOWN_S * 1000 - nowMs;
    if (waitMs > 0 && !urgent) return { ok: false as const, waitMs };
    tx.set(SUMMARY(), { lastAttemptAt: ts(nowMs) }, { merge: true });
    return {
      ok: true as const,
      prevAttempt: snap.get("lastAttemptAt") ?? null,
      hasText: !!snap.get("text"),
    };
  });
  if (!claim.ok) return { status: "cooldown", retryAfterSeconds: Math.ceil(claim.waitMs / 1000) };

  try {
    const raw = await providers().model.generate({ system: SYSTEM, prompt: prompt(lines) });
    const text = raw.replace(/\s+/g, " ").trim().slice(0, AI_SUMMARY_MAX_CHARS);
    if (text.length === 0) throw new Error("empty");
    await SUMMARY().set({ text, lastUpdated: ts(nowMs), statuses }, { merge: true });
    return { status: "updated", text };
  } catch (e) {
    await logError({ source: SOURCE, code: "AI_FAILED", message: String(e), nowMs });
    if (!claim.hasText) {
      const text = fallbackSummary(lines);
      await SUMMARY().set({ text, lastUpdated: ts(nowMs), statuses }, { merge: true });
      return { status: "fallback", text };
    }
    // Keep the old text; release the cooldown so a manual retry is possible.
    await SUMMARY().set({ lastAttemptAt: claim.prevAttempt }, { merge: true });
    return { status: "kept" };
  }
}

export const generateClientFlowSummaryOnChange = onDocumentUpdated(
  { document: "devices/{deviceId}", secrets: MODEL_SECRETS },
  async (event) => {
    if (event.data?.before.data()?.flowStatus === event.data?.after.data()?.flowStatus) return;
    if (!event.data?.after.get("ownerUid")) return;
    await refreshSummary();
  },
);

export const generateClientFlowSummary = onCall({ secrets: MODEL_SECRETS }, async (request) => {
  requireClient(request);
  const r = await refreshSummary();
  if (r.status === "cooldown") {
    throw new HttpsError("resource-exhausted", "Summary cooldown.", {
      code: "COOLDOWN",
      retryAfterSeconds: r.retryAfterSeconds,
    });
  }
  if (r.status === "kept") {
    throw new HttpsError("unavailable", "Couldn't update the summary.", { code: "AI_FAILED" });
  }
  const snap = await SUMMARY().get();
  return { text: snap.get("text") ?? null, lastUpdated: ms(snap.get("lastUpdated")) };
});
