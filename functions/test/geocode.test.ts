import { describe, expect, it } from "vitest";
import { cacheKey, normalizeQuery, parsePlaces } from "../src/lib/geocode";

describe("place search helpers", () => {
  it("normalizes queries so equal searches share one cache entry", () => {
    expect(normalizeQuery("  San  Fabian,   Pangasinan ")).toBe("san fabian, pangasinan");
    expect(cacheKey(normalizeQuery("SAN FABIAN")!)).toBe(cacheKey(normalizeQuery("san fabian")!));
    expect(normalizeQuery("a")).toBeNull();
    expect(normalizeQuery("x".repeat(101))).toBeNull();
    expect(normalizeQuery(42)).toBeNull();
  });

  it("parses Nominatim jsonv2: lat/lon strings, drops bad rows, keeps at most 5", () => {
    const row = (lat: string, lon: string, name = "Dagupan, Pangasinan, Philippines") => ({
      display_name: name,
      lat,
      lon,
    });
    const places = parsePlaces([
      row("16.0433", "120.3333"),
      row("not a number", "120"),
      row("95", "120"),
      { lat: "16", lon: "120" },
      row("16.1", "120.4", "x".repeat(200)),
      row("16.2", "120.5"),
      row("16.3", "120.6"),
      row("16.4", "120.7"),
      row("16.5", "120.8"),
    ]);
    expect(places).toHaveLength(5);
    expect(places[0]).toEqual({
      name: "Dagupan, Pangasinan, Philippines",
      lat: 16.0433,
      lng: 120.3333,
    });
    expect(places[1]!.name.length).toBe(160);
    expect(parsePlaces({ error: "x" })).toEqual([]);
  });
});
