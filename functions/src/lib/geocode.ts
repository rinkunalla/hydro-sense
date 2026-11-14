// Pure helpers for place search (Nominatim jsonv2). The service returns lat/lon as
// strings; anything malformed is dropped rather than shown.
import { GEOCODE_MAX_RESULTS, GEOCODE_QUERY_MAX, GEOCODE_QUERY_MIN } from "../config";
import { sha256Hex } from "./tokens";

export interface Place {
  /** "Ditsch, Lindower Straße, ..." (display_name), cut to 160 characters. */
  name: string;
  lat: number;
  lng: number;
}

/** Trims, collapses spaces and lowercases, so equal searches share one cache entry. */
export function normalizeQuery(q: unknown): string | null {
  if (typeof q !== "string") return null;
  const n = q.trim().replace(/\s+/g, " ").toLowerCase();
  return n.length >= GEOCODE_QUERY_MIN && n.length <= GEOCODE_QUERY_MAX ? n : null;
}

export const cacheKey = (normalized: string) => sha256Hex(`ph:${normalized}`);

export function parsePlaces(body: unknown): Place[] {
  if (!Array.isArray(body)) return [];
  const out: Place[] = [];
  for (const r of body) {
    if (typeof r !== "object" || r === null) continue;
    const o = r as Record<string, unknown>;
    const lat = Number(o.lat);
    const lng = Number(o.lon);
    const name = typeof o.display_name === "string" ? o.display_name.trim() : "";
    if (!name || !Number.isFinite(lat) || !Number.isFinite(lng)) continue;
    if (Math.abs(lat) > 90 || Math.abs(lng) > 180) continue;
    out.push({ name: name.length > 160 ? `${name.slice(0, 157)}...` : name, lat, lng });
    if (out.length >= GEOCODE_MAX_RESULTS) break;
  }
  return out;
}
