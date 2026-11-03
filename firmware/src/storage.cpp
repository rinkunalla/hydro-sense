#include "storage.h"

#include <Preferences.h>
#include <string.h>

namespace hs::storage {

static Preferences prefs;

void begin() { prefs.begin("hs", false); }

bool loadToken(char* out, size_t cap) {
  const size_t n = prefs.getString("token", out, cap);
  return n > 1;
}

void saveToken(const char* token) {
  char current[96] = {};
  prefs.getString("token", current, sizeof current);
  if (strcmp(current, token) != 0) prefs.putString("token", token);
}

void clearToken() { prefs.remove("token"); }

Cutoffs loadCutoffs() {
  Cutoffs c;
  c.low = prefs.getFloat("low", STARTER_LOW_FLOW_CUTOFF);
  c.normal = prefs.getFloat("normal", STARTER_NORMAL_FLOW_CUTOFF);
  // A corrupt NVS falls back to the starter cutoffs (docs/ERROR_HANDLING.md section 5).
  if (!(c.low > 0 && c.low < c.normal && c.normal <= FLOW_RATE_MAX)) c = Cutoffs();
  return c;
}

void saveCutoffsIfChanged(const Cutoffs& c) {
  const Cutoffs stored = loadCutoffs();
  if (stored.low != c.low) prefs.putFloat("low", c.low);
  if (stored.normal != c.normal) prefs.putFloat("normal", c.normal);
}

bool loadGps(double& lat, double& lng) {
  if (!prefs.getBool("gps", false)) return false;
  lat = prefs.getDouble("lat", 0);
  lng = prefs.getDouble("lng", 0);
  return true;
}

void saveGps(double lat, double lng) {
  prefs.putDouble("lat", lat);
  prefs.putDouble("lng", lng);
  prefs.putBool("gps", true);
}

}  // namespace hs::storage
