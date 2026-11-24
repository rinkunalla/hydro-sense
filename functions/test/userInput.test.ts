import { describe, expect, it } from "vitest";
import {
  confirmMatches,
  defaultNickname,
  e164,
  normalizePhMobile,
  parseDeviceId,
  parseDeviceName,
  parseEmail,
  parseName,
  parseOptionalEmail,
  parseOptionalPhone,
  parsePassword,
  parseUsername,
  staffLoginEmail,
} from "../src/lib/userInput";
import { newOneTimeToken, uidOfToken } from "../src/lib/tokens";

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

  it("device names are trimmed, 1 to 24 characters", () => {
    expect(parseDeviceName("  Main   pipe ")).toBe("Main pipe");
    expect(() => parseDeviceName("  ")).toThrow();
    expect(() => parseDeviceName("x".repeat(25))).toThrow();
  });

  it("optional contacts: undefined keeps, null or blank removes, else validated", () => {
    expect(parseOptionalPhone(undefined)).toBeUndefined();
    expect(parseOptionalPhone(null)).toBeNull();
    expect(parseOptionalPhone("  ")).toBeNull();
    expect(parseOptionalPhone("0917 123 4567")).toBe("639171234567");
    expect(() => parseOptionalPhone("12345")).toThrow();
    expect(parseOptionalEmail("")).toBeNull();
    expect(parseOptionalEmail(" Ana@X.ph ")).toBe("ana@x.ph");
    expect(() => parseOptionalEmail("ana@")).toThrow();
  });

  it("passwords are 8 to 128 characters", () => {
    expect(parsePassword("12345678")).toBe("12345678");
    expect(() => parsePassword("1234567")).toThrow();
    expect(() => parsePassword("x".repeat(129))).toThrow();
    expect(() => parsePassword(12345678)).toThrow();
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

describe("staff usernames (D64)", () => {
  const code = (v: unknown) => {
    try {
      parseUsername(v);
      return "ok";
    } catch (e) {
      return (e as { details?: { code?: string } }).details?.code;
    }
  };

  it("accepts a plain name and stores it in one form, whatever the case or spaces", () => {
    expect(parseUsername("juan")).toBe("juan");
    expect(parseUsername("  Juan ")).toBe(parseUsername("juan"));
  });

  it("refuses too short, too long, spaces inside and non-strings with USERNAME_INVALID", () => {
    for (const bad of ["ab", "x".repeat(21), "juan dela", "", null, 42]) {
      expect(code(bad)).toBe("USERNAME_INVALID");
    }
  });

  it("the hidden sign-in address is never a real mailbox", () => {
    expect(staffLoginEmail("juan")).toBe("juan@staff.hydrosense.invalid");
  });
});

describe("one-time tokens", () => {
  it("carry their uid and hash differently from the token", () => {
    const { token, hash } = newOneTimeToken("uid123");
    expect(uidOfToken(token)).toBe("uid123");
    expect(hash).not.toBe(token);
    expect(uidOfToken("nodot")).toBeNull();
    expect(uidOfToken(5)).toBeNull();
  });
});
