import { GoogleGenAI, ThinkingLevel } from "@google/genai";
import { defineSecret, defineString } from "firebase-functions/params";
import { createTransport, type Transporter } from "nodemailer";
import {
  AI_MAX_OUTPUT_TOKENS,
  AI_THINKING_LEVEL,
  AI_TIMEOUT_MS,
  ALERT_EMAIL_FROM_NAME,
  GEMINI_MODEL_DEFAULT,
  PROVIDER_TIMEOUT_MS,
  SEMAPHORE_URL,
} from "../config";

export const GEMINI_API_KEY = defineSecret("GEMINI_API_KEY");
export const SEMAPHORE_API_KEY = defineSecret("SEMAPHORE_API_KEY");
export const GMAIL_USER = defineSecret("GMAIL_USER");
export const GMAIL_APP_PASSWORD = defineSecret("GMAIL_APP_PASSWORD");
export const GEMINI_MODEL = defineString("GEMINI_MODEL", { default: GEMINI_MODEL_DEFAULT });

export const ALERT_SECRETS = [SEMAPHORE_API_KEY, GMAIL_USER, GMAIL_APP_PASSWORD];
export const MODEL_SECRETS = [GEMINI_API_KEY];

export interface SmsSender {
  /** Throws on any failure. */
  send(number: string, message: string): Promise<void>;
}

export interface EmailSender {
  /** Throws on any failure. */
  send(to: string, subject: string, text: string): Promise<void>;
}

export interface ModelRequest {
  system: string;
  prompt: string;
  /** When set, the model must answer with JSON matching this schema. */
  jsonSchema?: Record<string, unknown>;
}

export interface TextModel {
  /** Returns the model text; throws on failure, timeout or empty output. */
  generate(req: ModelRequest): Promise<string>;
}

export interface Providers {
  sms: SmsSender;
  email: EmailSender;
  model: TextModel;
}

class SemaphoreSms implements SmsSender {
  async send(number: string, message: string) {
    const res = await fetch(SEMAPHORE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ apikey: SEMAPHORE_API_KEY.value(), number, message }),
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
    });
    const body: unknown = await res.json().catch(() => null);
    if (!res.ok) throw new Error(`Semaphore HTTP ${res.status}`);
    const first = Array.isArray(body) ? (body[0] as { status?: string } | undefined) : undefined;
    if (!first) throw new Error("Semaphore returned no message");
    if (first.status === "Failed") throw new Error("Semaphore message status Failed");
  }
}

class GmailEmail implements EmailSender {
  private transporter: Transporter | null = null;

  async send(to: string, subject: string, text: string) {
    this.transporter ??= createTransport({
      service: "gmail",
      auth: { user: GMAIL_USER.value(), pass: GMAIL_APP_PASSWORD.value() },
      connectionTimeout: PROVIDER_TIMEOUT_MS,
      socketTimeout: PROVIDER_TIMEOUT_MS,
    });
    await this.transporter.sendMail({
      from: `"${ALERT_EMAIL_FROM_NAME}" <${GMAIL_USER.value()}>`,
      to,
      subject,
      text,
    });
  }
}

class GeminiModel implements TextModel {
  async generate(req: ModelRequest) {
    const ai = new GoogleGenAI({ apiKey: GEMINI_API_KEY.value() });
    // D1: no temperature/top_p/top_k and no prefilled model turns.
    const res = await ai.models.generateContent({
      model: GEMINI_MODEL.value(),
      contents: req.prompt,
      config: {
        systemInstruction: req.system,
        maxOutputTokens: AI_MAX_OUTPUT_TOKENS,
        httpOptions: { timeout: AI_TIMEOUT_MS },
        thinkingConfig: { thinkingLevel: ThinkingLevel[AI_THINKING_LEVEL] },
        ...(req.jsonSchema
          ? { responseMimeType: "application/json", responseJsonSchema: req.jsonSchema }
          : {}),
      },
    });
    const text = res.text?.trim();
    if (!text) throw new Error(`Empty model output (${res.candidates?.[0]?.finishReason ?? "?"})`);
    return text;
  }
}

/**
 * In the emulator, messages and model calls are logged instead of sent unless
 * HYDROSENSE_REAL_PROVIDERS=1, so simulator runs never spend SMS credits.
 */
class DryRun implements Providers {
  sms: SmsSender = {
    send: async (_n, message) => {
      console.log(JSON.stringify({ severity: "INFO", event: "sms_dry_run", length: message.length }));
    },
  };
  email: EmailSender = {
    send: async (_to, subject) => {
      console.log(JSON.stringify({ severity: "INFO", event: "email_dry_run", subject }));
    },
  };
  model: TextModel = {
    generate: async (req) => {
      if (req.jsonSchema) throw new Error("Dry run: no model output");
      return "Dry run: the water flow summary appears here when real providers are enabled.";
    },
  };
}

let override: Providers | null = null;
let real: Providers | null = null;

/** Tests inject fakes; pass null to restore the default. */
export function setProviders(p: Providers | null) {
  override = p;
}

export function providers(): Providers {
  if (override) return override;
  if (process.env.FUNCTIONS_EMULATOR === "true" && process.env.HYDROSENSE_REAL_PROVIDERS !== "1") {
    return new DryRun();
  }
  real ??= { sms: new SemaphoreSms(), email: new GmailEmail(), model: new GeminiModel() };
  return real;
}
