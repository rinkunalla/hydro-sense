// Battery math and low-voltage protection (D2, section 5 rules 4 and 8). Pure logic.
#pragma once

#include <stdint.h>

#include "config.h"

namespace hs {

/** Pack voltage from the divider midpoint in millivolts (30k/10k, ratio 0.25). */
float packVoltageFromMv(uint32_t midpointMv);

/** False when the divider reads outside any real pack (disconnected or miswired). */
bool batteryPlausible(float packV, uint8_t cells = BATTERY_SERIES_CELLS);

/** (Vpack - 3.3 N) / (0.9 N), clamped 0 to 100. */
uint8_t batteryPercent(float packV, uint8_t cells = BATTERY_SERIES_CELLS);

/**
 * Sleep after LOW_VOLTAGE_CONFIRM_READINGS consecutive readings below the sleep
 * level; never on a battery fault (the reading is unknown).
 */
class LowVoltageGuard {
 public:
  /** Feed one reading (about once a minute). Returns true when the device should sleep. */
  bool update(float packV, bool fault, uint8_t cells = BATTERY_SERIES_CELLS);
  void reset() { below_ = 0; }

 private:
  uint8_t below_ = 0;
};

/** On wake from low-voltage sleep: resume only at the higher resume level. */
bool canResume(float packV, bool fault, uint8_t cells = BATTERY_SERIES_CELLS);

}  // namespace hs
