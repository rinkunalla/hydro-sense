// Device protocol bodies (CLAUDE.md section 6, Device protocol). Do not rename fields.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "flow.h"
#include "scheduler.h"

namespace hs {

struct Reading {
  Status status = Status::Unknown;
  float flowRate = 0;
  float pulseHz = 0;
  float batteryVoltage = 0;
  bool batteryFault = false;
  bool gpsValid = false;
  double lat = 0;
  double lng = 0;
  int rssi = 0;
  const char* firmware = "";
  const char* resetReason = nullptr;  // sent once after an abnormal reset
  Trigger trigger = Trigger::Heartbeat;
  bool lowVoltageSleep = false;
  uint32_t heartbeatS = HEARTBEAT_S;  // tells the server when to call it offline
};

/** Writes the deviceIngest body into out; returns its length, 0 if it did not fit. */
size_t buildIngestBody(const Reading& r, char* out, size_t cap);

/** Writes the registerDevice body; returns its length, 0 if it did not fit. */
size_t buildRegisterBody(const char* deviceId, const char* firmware, char* out, size_t cap);

struct Cutoffs {
  float low = STARTER_LOW_FLOW_CUTOFF;
  float normal = STARTER_NORMAL_FLOW_CUTOFF;
};

/** Reads lowFlowCutoff/normalFlowCutoff from an ok response; false if missing or out of order. */
bool parseCutoffs(const char* json, size_t len, Cutoffs& out);

struct Pace {
  uint32_t heartbeatS = HEARTBEAT_S;
  uint32_t rateMinIntervalS = RATE_REPORT_MIN_INTERVAL_S;
};

/** Reads heartbeatS/rateMinIntervalS from an ok response; false if either is missing. */
bool parsePace(const char* json, size_t len, Pace& out);

/** Reads `token` from a registerDevice ok response into out (cap includes the terminator). */
bool parseToken(const char* json, size_t len, char* out, size_t cap);

/** Reads `code` from an error response ("" if absent). */
void parseErrorCode(const char* json, size_t len, char* out, size_t cap);

}  // namespace hs
