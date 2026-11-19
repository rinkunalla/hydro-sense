import { getMessaging } from "firebase-admin/messaging";
import { defineSecret } from "firebase-functions/params";
import { createTransport, type Transporter } from "nodemailer";
import {
  ALERT_CHANNEL_ID,
  ALERT_EMAIL_FROM_NAME,
  PROVIDER_TIMEOUT_MS,
  SEMAPHORE_OTP_URL,
  SEMAPHORE_URL,
} from "../config";

export const SEMAPHORE_API_KEY = defineSecret("SEMAPHORE_API_KEY");
export const GMAIL_USER = defineSecret("GMAIL_USER");
export const GMAIL_APP_PASSWORD = defineSecret("GMAIL_APP_PASSWORD");
// Server key restricted to Places API (New) (D46); never in the app.
export const GOOGLE_PLACES_KEY = defineSecret("GOOGLE_PLACES_KEY");

export const ALERT_SECRETS = [SEMAPHORE_API_KEY, GMAIL_USER, GMAIL_APP_PASSWORD];
export const MAIL_SECRETS = [GMAIL_USER, GMAIL_APP_PASSWORD];
export const OTP_SECRETS = [SEMAPHORE_API_KEY, GMAIL_USER, GMAIL_APP_PASSWORD];

export interface SmsSender {
  /** Throws on any failure. */
  send(number: string, message: string): Promise<void>;
}

export interface EmailSender {
  /** Throws on any failure. */
  send(to: string, subject: string, text: string): Promise<void>;
}

export interface OtpSender {
  /**
   * Sends a sign-in code on Semaphore's OTP route. message contains {otp}.
   * Returns the code actually sent (Semaphore echoes it). Throws on any failure.
   */
  send(number: string, message: string, code: string): Promise<string>;
}

export interface PushResult {
  /** Installations that received it. */
  sent: number;
  /** Installation IDs FCM reports as gone (app removed or reinstalled): delete them. */
  stale: string[];
}

export interface PushSender {
  /** Sends one notification to several app installations (FIDs). Throws only if the call fails. */
  send(
    fids: string[],
    title: string,
    body: string,
    data: Record<string, string>,
  ): Promise<PushResult>;
}

export interface Providers {
  sms: SmsSender;
  email: EmailSender;
  otp: OtpSender;
  push: PushSender;
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

/** OTP route: priority delivery, 2 credits per SMS, only for codes (Semaphore docs). */
class SemaphoreOtp implements OtpSender {
  async send(number: string, message: string, code: string) {
    const res = await fetch(SEMAPHORE_OTP_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ apikey: SEMAPHORE_API_KEY.value(), number, message, code }),
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
    });
    const body: unknown = await res.json().catch(() => null);
    if (!res.ok) throw new Error(`Semaphore OTP HTTP ${res.status}`);
    const first = Array.isArray(body)
      ? (body[0] as { status?: string; code?: unknown } | undefined)
      : undefined;
    if (!first) throw new Error("Semaphore OTP returned no message");
    if (first.status === "Failed") throw new Error("Semaphore OTP status Failed");
    // The docs name the parameter both code and otp: trust the echoed code if present.
    return first.code === undefined || first.code === null ? code : String(first.code);
  }
}

/** Codes meaning the installation will never receive again (Admin SDK messaging errors). */
const STALE_PUSH = ["installation-id-not-registered", "registration-token-not-registered"];

/** FCM HTTP v1 through the Admin SDK; FIDs, not the deprecated registration tokens. */
class FcmPush implements PushSender {
  async send(fids: string[], title: string, body: string, data: Record<string, string>) {
    const res = await getMessaging().sendEachForMulticast({
      fids,
      notification: { title, body },
      data,
      // The app's high-importance "alerts" channel pops the alert up on screen
      // with sound, like a chat message, and shows it on the lock screen.
      android: {
        priority: "high",
        notification: {
          channelId: ALERT_CHANNEL_ID,
          priority: "max",
          defaultSound: true,
          defaultVibrateTimings: true,
          visibility: "public",
        },
      },
    });
    const stale = res.responses.flatMap((r, i) =>
      !r.success && STALE_PUSH.some((c) => r.error?.code?.endsWith(c)) ? [fids[i]!] : [],
    );
    if (res.successCount === 0 && stale.length < fids.length) {
      const code = res.responses.find((r) => !r.success)?.error?.code ?? "unknown";
      throw new Error(`FCM failed: ${code}`);
    }
    return { sent: res.successCount, stale };
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

/**
 * In the emulator, messages are logged instead of sent unless
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
  push: PushSender = {
    send: async (fids, title) => {
      console.log(JSON.stringify({ severity: "INFO", event: "push_dry_run", to: fids.length, title }));
      return { sent: fids.length, stale: [] };
    },
  };
  // Emulator only: the code is logged so a developer can finish the flow locally.
  otp: OtpSender = {
    send: async (_n, _m, code) => {
      console.log(JSON.stringify({ severity: "INFO", event: "otp_dry_run", code }));
      return code;
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
  real ??= {
    sms: new SemaphoreSms(),
    email: new GmailEmail(),
    otp: new SemaphoreOtp(),
    push: new FcmPush(),
  };
  return real;
}
