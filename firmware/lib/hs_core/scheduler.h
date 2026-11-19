// Upload rules A/B/C. Pure logic, driven once per second.
#pragma once

#include <stdint.h>

#include "config.h"
#include "flow.h"

namespace hs {

enum class Trigger : uint8_t { None, StatusChange, RateChange, Heartbeat };

/** Protocol names: "status_change", "rate_change", "heartbeat". */
const char* triggerName(Trigger t);

struct UploadDecision {
  Trigger trigger = Trigger::None;
  Status status = Status::Unknown;  // the confirmed status to report
  float rateLpm = 0;
};

class UploadScheduler {
 public:
  /** Call every second with the classified status and current rate. */
  UploadDecision tick(uint32_t nowS, Status classified, float rateLpm);

  /** After a reconnect: upload the current state on the next tick (Rule A). */
  void requestImmediate() { immediate_ = true; }

  Status confirmed() const { return confirmed_; }

  /** Upload pace from the server reply; values are clamped to config.h ranges. */
  void setPace(uint32_t heartbeatS, uint32_t rateMinIntervalS);
  uint32_t heartbeatS() const { return heartbeatS_; }

 private:
  UploadDecision send(uint32_t nowS, Trigger t, float rate);

  Status confirmed_ = Status::Unknown;
  Status pending_ = Status::Unknown;
  uint32_t pendingSince_ = 0;
  bool hasPending_ = false;
  bool immediate_ = false;
  bool sentAny_ = false;
  uint32_t lastUpload_ = 0;
  uint32_t lastStatusUpload_ = 0;
  uint32_t lastRateUpload_ = 0;
  float lastSentRate_ = 0;
  uint32_t heartbeatS_ = HEARTBEAT_S;
  uint32_t rateMinIntervalS_ = RATE_REPORT_MIN_INTERVAL_S;
};

}  // namespace hs
