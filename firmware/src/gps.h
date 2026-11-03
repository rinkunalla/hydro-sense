// NEO-6M: acquire a fix (non-blocking, 5 min timeout), save it if the device moved
// more than 30 m, then put the receiver into timed backup sleep until the daily recheck.
#pragma once

#include <stdint.h>

namespace hs::gps {

void begin();

/** Call often from the network task; never blocks. */
void poll(uint32_t nowMs);

/** Backup-sleep the receiver now (before deep sleep). */
void sleepFor(uint32_t durationMs);

}  // namespace hs::gps
