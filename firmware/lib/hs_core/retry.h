// Reactions to server responses. Pure logic.
#pragma once

#include <stdint.h>

#include "config.h"

namespace hs {

/** Exponential backoff: BACKOFF_MIN_S doubling to BACKOFF_MAX_S. */
class Backoff {
 public:
  uint32_t next();
  void reset() { current_ = 0; }

 private:
  uint32_t current_ = 0;
};

enum class Action : uint8_t {
  Ok,          // success
  Reregister,  // ingest 401: call registerDevice once
  Drop,        // 400: do not resend this payload; send the next window
  RetryAfter,  // wait delayS (registration refused)
  Backoff,     // network error, timeout, TLS or 5xx: exponential backoff
};

struct Reaction {
  Action action;
  uint32_t delayS;  // for RetryAfter
};

/** httpStatus 0 means no response (network, timeout or TLS failure). */
Reaction reactToIngest(int httpStatus);
Reaction reactToRegister(int httpStatus);

enum class Stuck : uint8_t { No, WifiLost, NoResponse };

/**
 * Decides when the network task should restart the device instead of staying silent:
 * Wi-Fi down for WIFI_LOST_RESTART_S outside the setup portal (the core stops
 * reconnecting after some disconnect reasons), or registered and online with no HTTP
 * response at all for NO_RESPONSE_RESTART_S (a stuck TLS or network stack). Any HTTP
 * status counts as a response, so a server that answers with errors never causes a restart.
 */
class NetWatchdog {
 public:
  void noteResponse(uint32_t nowMs) { lastResponseMs_ = nowMs; }
  Stuck check(uint32_t nowMs, bool online, bool portalActive, bool registered);

 private:
  bool offline_ = false;
  uint32_t offlineSinceMs_ = 0;
  bool waiting_ = false;  // online and registered: expecting server replies
  uint32_t lastResponseMs_ = 0;
};

}  // namespace hs
