import { describe, expect, it } from "vitest";
import {
  confirmMatches,
  defaultNickname,
  e164,
  normalizePhMobile,
  parseDeviceId,
  parseEmail,
  parseLabel,
  parseName,
} from "../src/lib/userInput";

describe("admin input", () => {
  it("normalizes Philippine mobile numbers", () => {
    expect(normalizePhMobile("09171234567")).toBe("639171234567");
    expect(normalizePhMobile("+63 917 123 4567")).toBe("639171234567");
    expect(normalizePhMobile("639171234567")).toBe("639171234567");
    expect(normalizePhMobile("0917123456")).toBeNull();
    expect(normalizePhMobile("08171234567")).toBeNull();
    expect(normalizePhMobile(9171234567)).toBeNull();
    expect(e164("639171234567")).toBe("+639171234567");
  });

  it("trims names and limits them to 60 characters", () => {
    expect(parseName("  Juan   Dela  Cruz ")).toBe("Juan Dela Cruz");
    expect(() => parseName("   ")).toThrow();
    expect(() => parseName("x".repeat(61))).toThrow();
    expect(() => parseName(42)).toThrow();
  });

  it("lowercases emails and rejects bad ones", () => {
    expect(parseEmail(" Juan@Example.COM ")).toBe("juan@example.com");
    for (const bad of ["juan", "juan@", "a b@c.d", "", null])
      expect(() => parseEmail(bad)).toThrow();
  });

  it("labels are optional, trimmed, at most 24 characters", () => {
    expect(parseLabel(undefined)).toBeNull();
    expect(parseLabel("  ")).toBeNull();
    expect(parseLabel(" Unit 1 ")).toBe("Unit 1");
    expect(() => parseLabel("x".repeat(25))).toThrow();
  });

  it("normalizes device IDs", () => {
    expect(parseDeviceId("a1:b2:c3:d4:e5:f6")).toBe("A1B2C3D4E5F6");
    expect(() => parseDeviceId("123")).toThrow();
    expect(defaultNickname("A1B2C3D4E5F6")).toBe("Device E5F6");
  });

  it("typed confirmation ignores case and spacing only", () => {
    expect(confirmMatches(" juan  dela cruz", "Juan Dela Cruz")).toBe(true);
    expect(confirmMatches("Juan Dela", "Juan Dela Cruz")).toBe(false);
    expect(confirmMatches("Juan Dela Cruz.", "Juan Dela Cruz")).toBe(false);
    expect(confirmMatches("", "")).toBe(false);
    expect(confirmMatches(undefined, "Unit 1")).toBe(false);
  });
});

describe("sign-in code helpers", () => {
  it("makes 6-digit codes, keeps leading zeros, binds hashes to the account", async () => {
    const { generateCode, codeHash } = await import("../src/lib/otp");
    for (let i = 0; i < 200; i++) expect(generateCode()).toMatch(/^\d{6}$/);
    expect(codeHash("u1", "123456")).not.toBe(codeHash("u2", "123456"));
  });

  it("one-time tokens carry their uid and hash differently from the token", async () => {
    const { newOneTimeToken, uidOfToken } = await import("../src/lib/otp");
    const { token, hash } = newOneTimeToken("abc");
    expect(uidOfToken(token)).toBe("abc");
    expect(hash).not.toContain(token.split(".")[1]);
    expect(uidOfToken("no-dot")).toBeNull();
    expect(uidOfToken(42)).toBeNull();
  });

  it("masks a mobile as 0917 ••• 4567", async () => {
    const { maskPhone } = await import("../src/lib/otp");
    expect(maskPhone("639171234567")).toBe("0917 ••• 4567");
  });

  it("checks the resend gap before the daily limits", async () => {
    const { sendDecision } = await import("../src/lib/otp");
    const now = 1_000_000;
    expect(
      sendDecision({ lastSentMs: now - 10_000, phoneToday: 5, projectToday: 30 }, now),
    ).toEqual({
      kind: "cooldown",
      retryAfterSeconds: 50,
    });
    expect(
      sendDecision({ lastSentMs: now - 60_000, phoneToday: 5, projectToday: 0 }, now).kind,
    ).toBe("phone_limit");
    expect(sendDecision({ lastSentMs: null, phoneToday: 4, projectToday: 30 }, now).kind).toBe(
      "project_limit",
    );
    expect(sendDecision({ lastSentMs: null, phoneToday: 0, projectToday: 0 }, now).kind).toBe(
      "send",
    );
  });

  it("codeVerdict: right, wrong with tries left, expired, locked", async () => {
    const { codeVerdict } = await import("../src/lib/otp");
    const now = 1_000_000;
    const live = now + 60_000;
    expect(codeVerdict({ attempts: 0, expiresAtMs: live, matches: true }, now)).toEqual({
      kind: "ok",
    });
    expect(codeVerdict({ attempts: 0, expiresAtMs: live, matches: false }, now)).toEqual({
      kind: "invalid",
      triesLeft: 4,
    });
    expect(codeVerdict({ attempts: 4, expiresAtMs: live, matches: false }, now)).toEqual({
      kind: "invalid",
      triesLeft: 0,
    });
    expect(codeVerdict({ attempts: 5, expiresAtMs: live, matches: true }, now)).toEqual({
      kind: "locked",
    });
    expect(codeVerdict({ attempts: 0, expiresAtMs: now - 1, matches: true }, now)).toEqual({
      kind: "expired",
    });
  });
});
