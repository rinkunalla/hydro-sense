#include "protocol.h"

#include <ArduinoJson.h>
#include <math.h>
#include <string.h>

namespace hs {

static float round2(float v) { return roundf(v * 100.0f) / 100.0f; }

// Six decimals is about 10 cm: enough for a fixed device, and keeps the body short.
static double round6(double v) { return round(v * 1e6) / 1e6; }

size_t buildIngestBody(const Reading& r, char* out, size_t cap) {
  JsonDocument doc;
  doc["flowStatus"] = statusName(r.status);
  doc["flowRate"] = round2(r.flowRate);
  doc["pulseHz"] = round2(r.pulseHz);
  if (!r.batteryFault) doc["batteryVoltage"] = round2(r.batteryVoltage);
  doc["batteryFault"] = r.batteryFault;
  if (r.gpsValid) {
    doc["lat"] = round6(r.lat);
    doc["lng"] = round6(r.lng);
  }
  doc["gpsValid"] = r.gpsValid;
  doc["rssi"] = r.rssi;
  doc["firmware"] = r.firmware;
  if (r.resetReason) {
    doc["resetReason"] = r.resetReason;
  } else {
    doc["resetReason"] = nullptr;
  }
  doc["trigger"] = triggerName(r.trigger);
  if (r.lowVoltageSleep) doc["lowVoltageSleep"] = true;
  const size_t n = measureJson(doc);
  if (n + 1 > cap) return 0;
  return serializeJson(doc, out, cap);
}

size_t buildRegisterBody(const char* deviceId, const char* firmware, char* out, size_t cap) {
  JsonDocument doc;
  doc["deviceId"] = deviceId;
  doc["firmware"] = firmware;
  if (measureJson(doc) + 1 > cap) return 0;
  return serializeJson(doc, out, cap);
}

bool parseCutoffs(const char* json, size_t len, Cutoffs& out) {
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;
  JsonVariant low = doc["lowFlowCutoff"];
  JsonVariant normal = doc["normalFlowCutoff"];
  if (!low.is<float>() || !normal.is<float>()) return false;
  const float l = low.as<float>();
  const float n = normal.as<float>();
  if (!(l > 0 && l < n && n <= FLOW_RATE_MAX)) return false;
  out.low = l;
  out.normal = n;
  return true;
}

bool parseToken(const char* json, size_t len, char* out, size_t cap) {
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;
  const char* token = doc["token"];
  if (!token || strlen(token) + 1 > cap) return false;
  strcpy(out, token);
  return true;
}

void parseErrorCode(const char* json, size_t len, char* out, size_t cap) {
  out[0] = '\0';
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return;
  const char* code = doc["code"];
  if (code && strlen(code) + 1 <= cap) strcpy(out, code);
}

}  // namespace hs
