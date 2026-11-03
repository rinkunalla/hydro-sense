#include "power.h"

namespace hs {

float packVoltageFromMv(uint32_t midpointMv) {
  return static_cast<float>(midpointMv) / 1000.0f / BATTERY_DIVIDER_RATIO * BATTERY_CALIBRATION;
}

bool batteryPlausible(float v, uint8_t cells) {
  return v >= CELL_PLAUSIBLE_MIN_V * cells && v <= CELL_PLAUSIBLE_MAX_V * cells;
}

uint8_t batteryPercent(float v, uint8_t cells) {
  const float pct = (v - CELL_EMPTY_V * cells) / (CELL_SPAN_V * cells) * 100.0f;
  if (pct <= 0) return 0;
  if (pct >= 100) return 100;
  return static_cast<uint8_t>(pct + 0.5f);
}

bool LowVoltageGuard::update(float v, bool fault, uint8_t cells) {
  if (fault || !batteryPlausible(v, cells) || v >= LOW_VOLTAGE_SLEEP_CELL_V * cells) {
    below_ = 0;
    return false;
  }
  if (below_ < LOW_VOLTAGE_CONFIRM_READINGS) below_++;
  return below_ >= LOW_VOLTAGE_CONFIRM_READINGS;
}

bool canResume(float v, bool fault, uint8_t cells) {
  // An unknown reading cannot keep the device asleep forever.
  return fault || !batteryPlausible(v, cells) || v >= LOW_VOLTAGE_RESUME_CELL_V * cells;
}

}  // namespace hs
