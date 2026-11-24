// Live place search for the map. The app never
// holds the Places key: these callables add it, keep a daily cap per user and
// for the project (transaction), and honour an off switch
// (settings/places.enabled == false) that needs no app update.
import { HttpsError, onCall } from "firebase-functions/https";
import {
  PLACES_AUTOCOMPLETE_URL,
  PLACES_BIAS_RADIUS_M,
  PLACES_DETAILS_URL,
  PLACES_LANGUAGE,
  PLACES_PROJECT_DAILY_CAP,
  PLACES_REGION,
  PLACES_USER_DAILY_CAP,
  PROVIDER_TIMEOUT_MS,
} from "../config";
import { requireAdmin } from "../lib/auth";
import { C, db, ts } from "../lib/db";
import { logError } from "../lib/logError";
import {
  normalizeInput,
  parseBias,
  parseLocation,
  parseSuggestions,
  validPlaceId,
  validSessionToken,
  type Suggestion,
} from "../lib/places";
import { GOOGLE_PLACES_KEY } from "../lib/providers";
import { manilaDateKey } from "../lib/time";

const DAY_MS = 86_400_000;

export interface PlacesHttp {
  post(url: string, headers: Record<string, string>, body: unknown): Promise<unknown>;
  get(url: string, headers: Record<string, string>): Promise<unknown>;
}

const realHttp: PlacesHttp = {
  async post(url, headers, body) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`Places HTTP ${res.status}`);
    return res.json();
  },
  async get(url, headers) {
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) });
    if (!res.ok) throw new Error(`Places HTTP ${res.status}`);
    return res.json();
  },
};

let http: PlacesHttp = realHttp;

/** Tests inject a fake; pass null to restore the real one. */
export function setPlacesHttp(h: PlacesHttp | null) {
  http = h ?? realHttp;
}

const busy = (message: string, code: string) =>
  new HttpsError("resource-exhausted", message, { code });

/** Counts one call for the user and the project today, or refuses. */
async function countCall(uid: string, nowMs: number): Promise<void> {
  const day = manilaDateKey(nowMs);
  const projectRef = db.collection(C.rateLimits).doc(`places__${day}`);
  const userRef = db.collection(C.rateLimits).doc(`places__${uid}__${day}`);
  const expireAt = ts(nowMs + 2 * DAY_MS);
  await db.runTransaction(async (tx) => {
    const [p, u] = await Promise.all([tx.get(projectRef), tx.get(userRef)]);
    const pc = (p.get("count") as number | undefined) ?? 0;
    const uc = (u.get("count") as number | undefined) ?? 0;
    if (uc >= PLACES_USER_DAILY_CAP) {
      throw busy("You've searched a lot today. Try again tomorrow.", "PLACES_USER_LIMIT");
    }
    if (pc >= PLACES_PROJECT_DAILY_CAP) {
      throw busy("Place search is resting until tomorrow.", "PLACES_PROJECT_LIMIT");
    }
    tx.set(projectRef, { count: pc + 1, expireAt });
    tx.set(userRef, { count: uc + 1, expireAt });
  });
}

async function checkEnabled(): Promise<void> {
  const s = await db.collection(C.settings).doc("places").get();
  if (s.get("enabled") === false) {
    throw new HttpsError("failed-precondition", "Place search is off for now.", {
      code: "SEARCH_OFF",
    });
  }
}

const failed = () =>
  new HttpsError("unavailable", "Search isn't working right now.", { code: "SEARCH_FAILED" });

export async function suggestPlaces(
  uid: string,
  data: unknown,
  key: string,
  nowMs = Date.now(),
): Promise<Suggestion[]> {
  const d = (data ?? {}) as Record<string, unknown>;
  const input = normalizeInput(d.input);
  if (!input || !validSessionToken(d.sessionToken)) {
    throw new HttpsError("invalid-argument", "Type at least 3 letters.", { code: "QUERY_INVALID" });
  }
  await checkEnabled();
  await countCall(uid, nowMs);
  const bias = parseBias(d.near);
  try {
    const body = await http.post(
      PLACES_AUTOCOMPLETE_URL,
      {
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask":
          "suggestions.placePrediction.placeId,suggestions.placePrediction.text.text," +
          "suggestions.placePrediction.structuredFormat",
      },
      {
        input,
        sessionToken: d.sessionToken,
        includedRegionCodes: [PLACES_REGION],
        languageCode: PLACES_LANGUAGE,
        ...(bias
          ? {
              locationBias: {
                circle: {
                  center: { latitude: bias.lat, longitude: bias.lng },
                  radius: PLACES_BIAS_RADIUS_M,
                },
              },
            }
          : {}),
      },
    );
    return parseSuggestions(body);
  } catch (e) {
    await logError({ source: "placeSuggest", code: "SEARCH_FAILED", message: String(e), nowMs });
    throw failed();
  }
}

export async function locatePlace(
  uid: string,
  data: unknown,
  key: string,
  nowMs = Date.now(),
): Promise<{ lat: number; lng: number }> {
  const d = (data ?? {}) as Record<string, unknown>;
  if (!validPlaceId(d.placeId) || !validSessionToken(d.sessionToken)) {
    throw new HttpsError("invalid-argument", "Pick a place from the list.", {
      code: "QUERY_INVALID",
    });
  }
  await checkEnabled();
  await countCall(uid, nowMs);
  let at: { lat: number; lng: number } | null;
  try {
    // Only `location` (Essentials); the session ends here, so the
    // suggestions before it are billed as one session.
    at = parseLocation(
      await http.get(`${PLACES_DETAILS_URL}/${d.placeId}?sessionToken=${d.sessionToken}`, {
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask": "location",
      }),
    );
  } catch (e) {
    await logError({ source: "placeLocation", code: "SEARCH_FAILED", message: String(e), nowMs });
    throw failed();
  }
  if (!at) throw failed();
  return at;
}

export const placeSuggest = onCall({ secrets: [GOOGLE_PLACES_KEY] }, async (request) => {
  const uid = await requireAdmin(request);
  return { suggestions: await suggestPlaces(uid, request.data, GOOGLE_PLACES_KEY.value()) };
});

export const placeLocation = onCall({ secrets: [GOOGLE_PLACES_KEY] }, async (request) => {
  const uid = await requireAdmin(request);
  return locatePlace(uid, request.data, GOOGLE_PLACES_KEY.value());
});
