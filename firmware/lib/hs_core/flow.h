// Flow sensing and classification. Pure logic.
#pragma once

#include <stdint.h>

#include "config.h"

namespace hs {

enum class Status : uint8_t { Unknown, Normal, Low, None };

/** Protocol names: "Normal Flow", "Low Flow", "No Flow" (Unknown -> nullptr). */
const char* statusName(Status s);

/** Pulses since the previous reading of a free-running counter; safe across wraparound. */
inline uint32_t counterDelta(uint32_t now, uint32_t prev) { return now - prev; }

/**
 * The flow sensor as the server describes it (D69): pulses per second for
 * 1 L/min, and how many seconds of pulses to average. YF-S201 by default.
 */
struct Sensor {
  float pulsesPerLpm = PULSES_PER_LPM;
  uint32_t windowS = FLOW_WINDOW_S;
};

/** True when both values sit inside the config.h ranges. */
bool validSensor(const Sensor& s);

/** One pulse over the whole window, in L/min: the finest step the reading can take. */
float flowStepLpm(const Sensor& s);

/** Hysteresis for classify: FLOW_HYSTERESIS, or 1.5 pulse steps when that is larger. */
float flowHysteresis(const Sensor& s);

/**
 * The last FLOW_WINDOW_MAX_S one-second pulse counts. A reading sums the most
 * recent `windowS` of them, so a new window length from the server applies at
 * once and keeps the seconds already counted. One pulse per second is 0.133
 * L/min on a YF-S201, coarser than its No Flow cutoff, so classifying on 5 s
 * of pulses (0.027 L/min steps) keeps the low end from chattering; a ZJ-DN50
 * pulses about 37 times slower and needs 15 s for 0.33 L/min steps.
 */
class FlowWindow {
 public:
  void push(uint32_t pulsesThisSecond);
  /** Pulses per second over the last windowS seconds (fewer before that many are in). */
  float pulseHz(uint32_t windowS = FLOW_WINDOW_S) const;
  /** L/min for the sensor, capped at FLOW_RATE_MAX. */
  float rateLpm(const Sensor& s = Sensor()) const;
  void reset();

 private:
  uint32_t buf_[FLOW_WINDOW_MAX_S] = {};
  uint8_t next_ = 0;
  uint8_t filled_ = 0;
};

/**
 * Moving down crosses the cutoff; moving back up needs cutoff + hysteresis.
 * `current` is the last confirmed status (Unknown at boot: plain cutoffs).
 */
Status classify(float rateLpm, Status current, float lowCutoff, float normalCutoff,
                float hysteresis = FLOW_HYSTERESIS);

}  // namespace hs
