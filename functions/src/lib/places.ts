// Pure helpers for Google Places API (New) autocomplete and place location.
import { PLACES_INPUT_MAX, PLACES_INPUT_MIN } from "../config";

export interface Suggestion {
  placeId: string;
  /** "SM City Rosales" */
  main: string;
  /** "Carmen East, Rosales, Pangasinan, Philippines" (may be empty) */
  secondary: string;
}

/** Trimmed, spaces collapsed, 3 to 100 characters; else null. */
export function normalizeInput(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const n = v.trim().replace(/\s+/g, " ");
  return n.length >= PLACES_INPUT_MIN && n.length <= PLACES_INPUT_MAX ? n : null;
}

/** Google asks for URL- and filename-safe base64; the app sends a UUID v4. */
export const validSessionToken = (v: unknown): v is string =>
  typeof v === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(v);

/** Place IDs are URL-safe text; anything else never reaches the URL. */
export const validPlaceId = (v: unknown): v is string =>
  typeof v === "string" && /^[A-Za-z0-9_-]{4,300}$/.test(v);

/** An optional map centre for location bias; null when absent or invalid. */
export function parseBias(v: unknown): { lat: number; lng: number } | null {
  if (typeof v !== "object" || v === null) return null;
  const { lat, lng } = v as Record<string, unknown>;
  if (typeof lat !== "number" || typeof lng !== "number") return null;
  if (!(lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180)) return null;
  return { lat, lng };
}

const text = (v: unknown): string =>
  typeof v === "object" && v !== null && typeof (v as { text?: unknown }).text === "string"
    ? ((v as { text: string }).text).slice(0, 160)
    : "";

export function parseSuggestions(body: unknown): Suggestion[] {
  const list = (body as { suggestions?: unknown } | null)?.suggestions;
  if (!Array.isArray(list)) return [];
  const out: Suggestion[] = [];
  for (const s of list) {
    const p = (s as { placePrediction?: Record<string, unknown> } | null)?.placePrediction;
    if (!p || !validPlaceId(p.placeId)) continue;
    const f = (p.structuredFormat ?? {}) as Record<string, unknown>;
    const main = text(f.mainText) || text(p.text);
    if (!main) continue;
    out.push({ placeId: p.placeId, main, secondary: text(f.secondaryText) });
  }
  return out.slice(0, 5);
}

export function parseLocation(body: unknown): { lat: number; lng: number } | null {
  const loc = (body as { location?: Record<string, unknown> } | null)?.location;
  if (!loc) return null;
  return parseBias({ lat: loc.latitude, lng: loc.longitude });
}
