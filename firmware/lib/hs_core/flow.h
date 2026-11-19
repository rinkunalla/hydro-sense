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
 * Sliding sum of the last FLOW_WINDOW_S one-second pulse counts. One pulse per
 * second is 0.133 L/min, coarser than the No Flow cutoff, so classifying on 5 s
 * of pulses (0.027 L/min steps) keeps the low end from chattering.
 */
class FlowWindow {
 public:
  void push(uint32_t pulsesThisSecond);
  /** Average over the seconds collected so far (all FLOW_WINDOW_S once full). */
  float rateLpm() const;
  float pulseHz() const;
  void reset();

 private:
  uint32_t buf_[FLOW_WINDOW_S] = {};
  uint32_t sum_ = 0;
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
