// Place search for the map (UI spec 4.4/4.5). The app never calls Nominatim
// directly: this callable keeps the usage policy for every user together.
//  - one request per GEOCODE_MIN_GAP_MS for the whole app (transaction, D18)
//  - the app's own User-Agent, Philippines only, at most GEOCODE_MAX_RESULTS
//  - results cached in geocode_cache (TTL GEOCODE_CACHE_TTL_DAYS)
//  - an off switch (settings/geocoding.enabled == false) that needs no app update
import { HttpsError, onCall } from "firebase-functions/https";
import {
  GEOCODE_CACHE_TTL_DAYS,
  GEOCODE_COUNTRY,
  GEOCODE_MAX_RESULTS,
  GEOCODE_MAX_QUEUE_MS,
  GEOCODE_MIN_GAP_MS,
  GEOCODE_SLOT_LATE_MS,
  GEOCODE_USER_AGENT,
  NOMINATIM_URL,
  PROVIDER_TIMEOUT_MS,
} from "../config";
import { requireUser } from "../lib/auth";
import { C, db, ms, ts } from "../lib/db";
import { cacheKey, normalizeQuery, parsePlaces, type Place } from "../lib/geocode";
import { logError } from "../lib/logError";

const DAY_MS = 86_400_000;
const MAX_WAITS = 5;

export type GeocodeFetch = (url: string, headers: Record<string, string>) => Promise<unknown>;

const realFetch: GeocodeFetch = async (url, headers) => {
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) });
  if (!res.ok) throw new Error(`Nominatim HTTP ${res.status}`);
  return res.json();
};

let fetcher: GeocodeFetch = realFetch;

/** Tests inject a fake; pass null to restore the real one. */
export function setGeocodeFetch(f: GeocodeFetch | null) {
  fetcher = f ?? realFetch;
}

const sleep = (msec: number) => new Promise((r) => setTimeout(r, msec));

/**
 * Books the next free send time for a Nominatim request across all instances
 * and returns at that time. Booked times are GEOCODE_MIN_GAP_MS apart. A
 * commit can be slow, so a caller whose booked time already passed by more
 * than GEOCODE_SLOT_LATE_MS books again instead of sending: every send then happens
 * within GEOCODE_SLOT_LATE_MS of its booked time, so sends stay at least
 * GEOCODE_MIN_GAP_MS - GEOCODE_SLOT_LATE_MS (1 s) apart.
 */
async function claimSlot(): Promise<void> {
  const ref = db.collection(C.rateLimits).doc("nominatim");
  // Two transactions that both read a missing doc can both book it, so make
  // sure the doc exists first; from then on every booking works on one locked doc.
  await ref.create({ lastAt: ts(0) }).catch(() => undefined);
  for (let i = 0; i < MAX_WAITS; i++) {
    const slot = await db.runTransaction(async (tx) => {
      const last = ms((await tx.get(ref)).get("lastAt")) ?? 0;
      const now = Date.now();
      const next = Math.max(now, last + GEOCODE_MIN_GAP_MS);
      if (next - now > GEOCODE_MAX_QUEUE_MS) return null;
      tx.set(ref, { lastAt: ts(next), expireAt: ts(next + DAY_MS) });
      return next;
    });
    if (slot === null) break;
    const wait = slot - Date.now();
    if (wait > 0) await sleep(wait);
    else if (-wait > GEOCODE_SLOT_LATE_MS) continue;
    return;
  }
  throw new HttpsError("resource-exhausted", "Search is busy. Try again in a moment.", {
    code: "SEARCH_BUSY",
  });
}

export async function searchPlaces(query: unknown, nowMs = Date.now()): Promise<Place[]> {
  const q = normalizeQuery(query);
  if (!q) {
    throw new HttpsError("invalid-argument", "Type at least 2 characters.", {
      code: "QUERY_INVALID",
    });
  }
  const settings = await db.collection(C.settings).doc("geocoding").get();
  if (settings.get("enabled") === false) {
    throw new HttpsError("failed-precondition", "Place search is off for now.", {
      code: "SEARCH_OFF",
    });
  }

  const cacheRef = db.collection(C.geocodeCache).doc(cacheKey(q));
  const cached = await cacheRef.get();
  const fresh = (ms(cached.get("expireAt")) ?? 0) > nowMs;
  if (cached.exists && fresh) return cached.get("results") as Place[];

  await claimSlot();
  let places: Place[];
  try {
    const url =
      `${NOMINATIM_URL}?format=jsonv2&countrycodes=${GEOCODE_COUNTRY}` +
      `&limit=${GEOCODE_MAX_RESULTS}&accept-language=en&q=${encodeURIComponent(q)}`;
    places = parsePlaces(await fetcher(url, { "User-Agent": GEOCODE_USER_AGENT }));
  } catch (e) {
    await logError({ source: "searchPlace", code: "SEARCH_FAILED", message: String(e), nowMs });
    throw new HttpsError("unavailable", "Search isn't working right now.", {
      code: "SEARCH_FAILED",
    });
  }
  // The query text is not stored: only its hash (the doc ID) and the places.
  await cacheRef.set({ results: places, expireAt: ts(nowMs + GEOCODE_CACHE_TTL_DAYS * DAY_MS) });
  return places;
}

export const searchPlace = onCall(async (request) => {
  await requireUser(request);
  const places = await searchPlaces((request.data as { query?: unknown } | null)?.query);
  return { places, attribution: "© OpenStreetMap contributors" };
});
