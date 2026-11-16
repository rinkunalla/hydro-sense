#include "scheduler.h"

#include <math.h>

namespace hs {

const char* triggerName(Trigger t) {
  switch (t) {
    case Trigger::StatusChange:
      return "status_change";
    case Trigger::RateChange:
      return "rate_change";
    case Trigger::Heartbeat:
      return "heartbeat";
    default:
      return nullptr;
  }
}

static uint32_t clampU(uint32_t v, uint32_t lo, uint32_t hi) { return v < lo ? lo : v > hi ? hi : v; }

void UploadScheduler::setPace(uint32_t heartbeatS, uint32_t rateMinIntervalS) {
  heartbeatS_ = clampU(heartbeatS, HEARTBEAT_MIN_S, HEARTBEAT_MAX_S);
  rateMinIntervalS_ = clampU(rateMinIntervalS, RATE_INTERVAL_MIN_S, RATE_INTERVAL_MAX_S);
}

UploadDecision UploadScheduler::send(uint32_t nowS, Trigger t, float rate) {
  sentAny_ = true;
  lastUpload_ = nowS;
  lastSentRate_ = rate;
  if (t == Trigger::StatusChange) lastStatusUpload_ = nowS;
  if (t == Trigger::RateChange) lastRateUpload_ = nowS;
  return UploadDecision{t, confirmed_, rate};
}

UploadDecision UploadScheduler::tick(uint32_t nowS, Status classified, float rate) {
  // First reading after boot: report it at once.
  if (confirmed_ == Status::Unknown) {
    if (classified == Status::Unknown) return {};
    confirmed_ = classified;
    return send(nowS, Trigger::StatusChange, rate);
  }

  // Rule A: a new status must hold STATUS_CONFIRM_S; status uploads are
  // STATUS_MIN_INTERVAL_S apart (anti-flicker).
  if (classified != confirmed_) {
    if (!hasPending_ || pending_ != classified) {
      pending_ = classified;
      pendingSince_ = nowS;
      hasPending_ = true;
    }
    if (nowS - pendingSince_ >= STATUS_CONFIRM_S &&
        nowS - lastStatusUpload_ >= STATUS_MIN_INTERVAL_S) {
      confirmed_ = classified;
      hasPending_ = false;
      immediate_ = false;
      return send(nowS, Trigger::StatusChange, rate);
    }
  } else {
    hasPending_ = false;
  }

  if (immediate_) {
    immediate_ = false;
    return send(nowS, Trigger::StatusChange, rate);
  }

  // Rule B (suppressed while a new status is being confirmed).
  const float delta = fabsf(rate - lastSentRate_);
  if (!hasPending_ && delta >= RATE_REPORT_MIN_ABS &&
      delta >= (RATE_REPORT_DELTA_PCT / 100.0f) * lastSentRate_ &&
      nowS - lastRateUpload_ >= rateMinIntervalS_) {
    return send(nowS, Trigger::RateChange, rate);
  }

  // Rule C: heartbeat when nothing else was sent.
  if (!sentAny_ || nowS - lastUpload_ >= heartbeatS_) {
    return send(nowS, Trigger::Heartbeat, rate);
  }
  return {};
}

}  // namespace hs
