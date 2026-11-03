import { randomInt } from "node:crypto";
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/https";
import { CLIENT_NAME_MAX, PH_MOBILE_PATTERN, TEMP_PASSWORD_LENGTH } from "../config";
import { requireAdmin, requireClient } from "../lib/auth";
import { C, db, ts } from "../lib/db";
import { logError } from "../lib/logError";
import { GMAIL_APP_PASSWORD, GMAIL_USER, providers } from "../lib/providers";

const SOURCE = "createClientAccount";
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// No 0/O or 1/l/I, so a password read aloud or copied by hand is not misread.
const PASSWORD_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";

/** 09XXXXXXXXX, +639XXXXXXXXX or 639XXXXXXXXX -> 639XXXXXXXXX, else null. */
export function normalizePhMobile(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const m = PH_MOBILE_PATTERN.exec(input.replace(/[\s-]/g, ""));
  return m ? `639${m[1]}` : null;
}

export function temporaryPassword(): string {
  return Array.from({ length: TEMP_PASSWORD_LENGTH }, () =>
    PASSWORD_ALPHABET.charAt(randomInt(PASSWORD_ALPHABET.length)),
  ).join("");
}

interface CreateInput {
  name: string;
  email: string;
  phone: string;
  setupMethod: "email" | "temporary";
}

function parseInput(data: unknown): CreateInput {
  const d = (data ?? {}) as Record<string, unknown>;
  const invalid = (code: string, message: string) =>
    new HttpsError("invalid-argument", message, { code });
  const name = typeof d.name === "string" ? d.name.trim() : "";
  if (name.length < 1 || name.length > CLIENT_NAME_MAX) {
    throw invalid("NAME_INVALID", `Name must be 1 to ${CLIENT_NAME_MAX} characters.`);
  }
  const email = typeof d.email === "string" ? d.email.trim().toLowerCase() : "";
  if (!EMAIL_PATTERN.test(email)) throw invalid("EMAIL_INVALID", "Enter a valid email address.");
  const phone = normalizePhMobile(d.phone);
  if (!phone) throw invalid("PHONE_INVALID", "Enter a Philippine mobile number.");
  if (d.setupMethod !== "email" && d.setupMethod !== "temporary") {
    throw invalid("SETUP_METHOD_INVALID", "Choose email link or temporary password.");
  }
  return { name, email, phone, setupMethod: d.setupMethod };
}

/** Sets ownerUid on every unadopted device, on both devices and device_health (D10). */
async function adoptDevices(clientUid: string): Promise<number> {
  const orphans = await db.collection(C.devices).where("ownerUid", "==", null).get();
  const batch = db.batch();
  for (const d of orphans.docs) {
    batch.update(d.ref, { ownerUid: clientUid });
    batch.set(db.collection(C.deviceHealth).doc(d.id), { ownerUid: clientUid }, { merge: true });
  }
  if (orphans.size > 0) await batch.commit();
  return orphans.size;
}

export const createClientAccount = onCall(
  { secrets: [GMAIL_USER, GMAIL_APP_PASSWORD] },
  async (request) => {
    requireAdmin(request);
    const input = parseInput(request.data);
    const exists = () =>
      new HttpsError("already-exists", "A client account already exists.", {
        code: "CLIENT_EXISTS",
      });

    const systemRef = db.collection(C.config).doc("system");
    if ((await systemRef.get()).get("clientUid")) throw exists();

    const auth = getAuth();
    const password = temporaryPassword();
    let uid: string;
    try {
      uid = (await auth.createUser({ email: input.email, displayName: input.name, password })).uid;
    } catch (e) {
      if ((e as { code?: string }).code === "auth/email-already-exists") {
        throw new HttpsError("already-exists", "An account with this email already exists.", {
          code: "EMAIL_IN_USE",
        });
      }
      throw e;
    }

    try {
      // create() fails if another admin finished first; that call wins.
      await systemRef.create({ clientUid: uid, clientName: input.name, clientEmail: input.email });
    } catch {
      await auth.deleteUser(uid).catch(() => undefined);
      throw exists();
    }

    await auth.setCustomUserClaims(uid, { role: "client" });
    await db
      .collection(C.users)
      .doc(uid)
      .set({
        role: "client",
        email: input.email,
        phone: input.phone,
        displayName: input.name,
        mustChangePassword: input.setupMethod === "temporary",
        createdAt: ts(Date.now()),
      });
    const adopted = await adoptDevices(uid);

    if (input.setupMethod === "temporary") {
      return { uid, adopted, temporaryPassword: password };
    }
    try {
      const link = await auth.generatePasswordResetLink(input.email);
      await providers().email.send(
        input.email,
        "Set up your Hydro Sense account",
        [
          `Hello ${input.name},`,
          "",
          "An account has been created for you on Hydro Sense.",
          "Open this link to choose your password:",
          link,
          "",
          "Then sign in to the Hydro Sense app with this email address.",
        ].join("\n"),
      );
      return { uid, adopted, emailSent: true };
    } catch (e) {
      await logError({ source: SOURCE, code: "EMAIL_FAILED", message: String(e) });
      return { uid, adopted, emailSent: false };
    }
  },
);

export const confirmPasswordChanged = onCall(async (request) => {
  const uid = requireClient(request);
  await db.collection(C.users).doc(uid).set({ mustChangePassword: false }, { merge: true });
  return { ok: true };
});
