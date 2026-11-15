import { describe, expect, it } from "vitest";
import {
  normalizeInput,
  parseBias,
  parseLocation,
  parseSuggestions,
  validPlaceId,
  validSessionToken,
} from "../src/lib/places";

describe("Places helpers (D46)", () => {
  it("normalizes the typed text: 3 to 100 characters", () => {
    expect(normalizeInput("  SM   City ")).toBe("SM City");
    expect(normalizeInput("sm")).toBeNull();
    expect(normalizeInput("x".repeat(101))).toBeNull();
    expect(normalizeInput(42)).toBeNull();
  });

  it("accepts only URL-safe session tokens and place IDs", () => {
    expect(validSessionToken("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")).toBe(true);
    expect(validSessionToken("short")).toBe(false);
    expect(validSessionToken("has space here")).toBe(false);
    expect(validPlaceId("ChIJN1t_tDeuEmsRUsoyG83frY4")).toBe(true);
    expect(validPlaceId("../x")).toBe(false);
    expect(validPlaceId("a?b=c")).toBe(false);
  });

  it("parses suggestions, skipping query predictions and broken rows", () => {
    expect(
      parseSuggestions({
        suggestions: [
          { placePrediction: { placeId: "A1b2", text: { text: "Only text" } } },
          { queryPrediction: { text: { text: "pizza" } } },
          { placePrediction: { placeId: "bad id", text: { text: "x" } } },
          {
            placePrediction: {
              placeId: "C3d4",
              structuredFormat: { mainText: { text: "Main" }, secondaryText: { text: "Sub" } },
            },
          },
        ],
      }),
    ).toEqual([
      { placeId: "A1b2", main: "Only text", secondary: "" },
      { placeId: "C3d4", main: "Main", secondary: "Sub" },
    ]);
    expect(parseSuggestions({})).toEqual([]);
    expect(parseSuggestions(null)).toEqual([]);
  });

  it("parses the location and a map-centre bias", () => {
    expect(parseLocation({ location: { latitude: 16.1, longitude: 120.4 } })).toEqual({
      lat: 16.1,
      lng: 120.4,
    });
    expect(parseLocation({ location: { latitude: 91, longitude: 0 } })).toBeNull();
    expect(parseLocation({})).toBeNull();
    expect(parseBias({ lat: 16, lng: 120 })).toEqual({ lat: 16, lng: 120 });
    expect(parseBias({ lat: "16", lng: 120 })).toBeNull();
    expect(parseBias(null)).toBeNull();
  });
});
