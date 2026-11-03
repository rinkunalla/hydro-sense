// Small pure helpers: device ID, GPS distance, the u-blox sleep command, LED patterns.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace hs {

/** "aa:bb:cc:dd:ee:ff" -> "AABBCCDDEEFF" (CLAUDE.md section 4). False if not a MAC. */
bool deviceIdFromMac(const char* mac, char out[13]);

/** Great-circle distance in metres. */
double distanceMeters(double lat1, double lng1, double lat2, double lng2);

/**
 * UBX-RXM-PMREQ (class 0x02, id 0x41, 8-byte payload: duration ms, flags 0x02 =
 * backup). The receiver sleeps for durationMs, then wakes by itself. Writes 16
 * bytes to out and returns the length.
 */
size_t buildUbxBackupRequest(uint32_t durationMs, uint8_t out[16]);

enum class LedMode : uint8_t { Off, Connected, Connecting, Hotspot, Rejecting };

/** docs/ERROR_HANDLING.md section 5: solid, 1 Hz, 4 Hz, two quick blinks every 3 s. */
bool ledOn(LedMode mode, uint32_t ms);

}  // namespace hs
