#include "misc.h"

#include <ctype.h>
#include <math.h>

namespace hs {

bool deviceIdFromMac(const char* mac, char out[13]) {
  size_t n = 0;
  for (const char* p = mac; *p != '\0'; ++p) {
    if (*p == ':' || *p == '-') continue;
    if (!isxdigit(static_cast<unsigned char>(*p)) || n == 12) return false;
    out[n++] = static_cast<char>(toupper(static_cast<unsigned char>(*p)));
  }
  out[n] = '\0';
  return n == 12;
}

double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  constexpr double kEarthM = 6371000.0;
  constexpr double kRad = M_PI / 180.0;
  const double dLat = (lat2 - lat1) * kRad;
  const double dLng = (lng2 - lng1) * kRad;
  const double a = sin(dLat / 2) * sin(dLat / 2) +
                   cos(lat1 * kRad) * cos(lat2 * kRad) * sin(dLng / 2) * sin(dLng / 2);
  return 2 * kEarthM * atan2(sqrt(a), sqrt(1 - a));
}

size_t buildUbxBackupRequest(uint32_t durationMs, uint8_t out[16]) {
  const uint32_t flags = 0x02;
  uint8_t msg[] = {
      0xB5, 0x62, 0x02, 0x41, 0x08, 0x00,
      static_cast<uint8_t>(durationMs), static_cast<uint8_t>(durationMs >> 8),
      static_cast<uint8_t>(durationMs >> 16), static_cast<uint8_t>(durationMs >> 24),
      static_cast<uint8_t>(flags), static_cast<uint8_t>(flags >> 8),
      static_cast<uint8_t>(flags >> 16), static_cast<uint8_t>(flags >> 24),
      0, 0,
  };
  // 8-bit Fletcher checksum over class, id, length and payload.
  uint8_t a = 0, b = 0;
  for (size_t i = 2; i < 14; ++i) {
    a = static_cast<uint8_t>(a + msg[i]);
    b = static_cast<uint8_t>(b + a);
  }
  msg[14] = a;
  msg[15] = b;
  for (size_t i = 0; i < 16; ++i) out[i] = msg[i];
  return 16;
}

bool ledOn(LedMode mode, uint32_t ms) {
  switch (mode) {
    case LedMode::Connected:
      return true;
    case LedMode::Connecting:
      return ms % 1000 < 500;
    case LedMode::Hotspot:
      return ms % 250 < 125;
    case LedMode::Rejecting: {
      const uint32_t t = ms % 3000;
      return t < 100 || (t >= 200 && t < 300);
    }
    default:
      return false;
  }
}

}  // namespace hs
