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

  it("typed confirmation ignores case and spacing only (D42)", () => {
    expect(confirmMatches(" juan  dela cruz", "Juan Dela Cruz")).toBe(true);
    expect(confirmMatches("Juan Dela", "Juan Dela Cruz")).toBe(false);
    expect(confirmMatches("Juan Dela Cruz.", "Juan Dela Cruz")).toBe(false);
    expect(confirmMatches("", "")).toBe(false);
    expect(confirmMatches(undefined, "Unit 1")).toBe(false);
  });
});
