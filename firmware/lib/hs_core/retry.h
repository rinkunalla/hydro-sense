// Reactions to server responses (docs/ERROR_HANDLING.md section 5). Pure logic.
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

}  // namespace hs
