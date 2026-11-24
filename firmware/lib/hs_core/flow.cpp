#include "flow.h"

namespace hs {

const char* statusName(Status s) {
  switch (s) {
    case Status::Normal:
      return "Normal Flow";
    case Status::Low:
      return "Low Flow";
    case Status::None:
      return "No Flow";
    default:
      return nullptr;
  }
}

bool validSensor(const Sensor& s) {
  return s.pulsesPerLpm >= PULSES_PER_LPM_MIN && s.pulsesPerLpm <= PULSES_PER_LPM_MAX &&
         s.windowS >= FLOW_WINDOW_MIN_S && s.windowS <= FLOW_WINDOW_MAX_S;
}

float flowStepLpm(const Sensor& s) { return 1.0f / (static_cast<float>(s.windowS) * s.pulsesPerLpm); }

float flowHysteresis(const Sensor& s) {
  // A reading that swings by one pulse moves exactly one step; needing more
  // than a step to climb back over a cutoff keeps that swing from flipping
  // the status (with no float tie at exactly one step).
  const float band = FLOW_HYSTERESIS_STEPS * flowStepLpm(s);
  return band > FLOW_HYSTERESIS ? band : FLOW_HYSTERESIS;
}

void FlowWindow::push(uint32_t pulsesThisSecond) {
  buf_[next_] = pulsesThisSecond;
  next_ = (next_ + 1) % FLOW_WINDOW_MAX_S;
  if (filled_ < FLOW_WINDOW_MAX_S) filled_++;
}

float FlowWindow::pulseHz(uint32_t windowS) const {
  if (windowS > FLOW_WINDOW_MAX_S) windowS = FLOW_WINDOW_MAX_S;
  const uint32_t n = windowS < filled_ ? windowS : filled_;
  if (n == 0) return 0.0f;
  uint32_t sum = 0;
  for (uint32_t i = 1; i <= n; i++) sum += buf_[(next_ + FLOW_WINDOW_MAX_S - i) % FLOW_WINDOW_MAX_S];
  return static_cast<float>(sum) / n;
}

float FlowWindow::rateLpm(const Sensor& s) const {
  const float rate = pulseHz(s.windowS) / s.pulsesPerLpm;
  return rate > FLOW_RATE_MAX ? FLOW_RATE_MAX : rate;
}

void FlowWindow::reset() { *this = FlowWindow(); }

Status classify(float rate, Status current, float low, float normal, float h) {
  const float noCut = current == Status::None ? low + h : low;
  const float normalCut = current == Status::Normal ? normal : normal + h;
  if (current == Status::Unknown) {
    if (rate < low) return Status::None;
    return rate <= normal ? Status::Low : Status::Normal;
  }
  if (rate < noCut) return Status::None;
  if (rate <= normalCut) return Status::Low;
  return Status::Normal;
}

}  // namespace hs
