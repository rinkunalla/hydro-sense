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

void FlowWindow::push(uint32_t pulsesThisSecond) {
  if (filled_ == FLOW_WINDOW_S) sum_ -= buf_[next_];
  buf_[next_] = pulsesThisSecond;
  sum_ += pulsesThisSecond;
  next_ = (next_ + 1) % FLOW_WINDOW_S;
  if (filled_ < FLOW_WINDOW_S) filled_++;
}

float FlowWindow::pulseHz() const {
  return filled_ == 0 ? 0.0f : static_cast<float>(sum_) / filled_;
}

float FlowWindow::rateLpm() const {
  float rate = pulseHz() / PULSES_PER_LPM;
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
