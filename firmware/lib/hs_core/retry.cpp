#include "retry.h"

namespace hs {

uint32_t Backoff::next() {
  current_ = current_ == 0 ? BACKOFF_MIN_S : current_ * 2;
  if (current_ > BACKOFF_MAX_S) current_ = BACKOFF_MAX_S;
  return current_;
}

Reaction reactToIngest(int s) {
  if (s >= 200 && s < 300) return {Action::Ok, 0};
  if (s == 401) return {Action::Reregister, 0};
  if (s == 400) return {Action::Drop, 0};
  return {Action::Backoff, 0};
}

Reaction reactToRegister(int s) {
  if (s >= 200 && s < 300) return {Action::Ok, 0};
  switch (s) {
    case 409:  // DEVICE_ACTIVE: just past the offline threshold it will be allowed
      return {Action::RetryAfter, REGISTER_ACTIVE_RETRY_S};
    case 400:  // malformed request: a firmware bug, so do not hammer the server
    case 401:  // PROVISIONING_KEY_INVALID
    case 403:  // DEVICE_REMOVED or DEVICE_NOT_ALLOWED
    case 429:  // REGISTER_RATE_LIMITED
      return {Action::RetryAfter, REGISTER_BLOCKED_RETRY_S};
    default:
      return {Action::Backoff, 0};
  }
}

}  // namespace hs
