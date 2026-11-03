#include "gps.h"

#include <Arduino.h>
#include <TinyGPSPlus.h>

#include "app_state.h"
#include "config.h"
#include "misc.h"
#include "storage.h"

namespace hs::gps {

static TinyGPSPlus parser;
static bool acquiring = true;
static uint32_t acquireStartMs = 0;
static uint32_t nextAcquireMs = 0;

void begin() {
  Serial2.begin(GPS_BAUD, SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);
  double lat, lng;
  if (storage::loadGps(lat, lng)) {
    Locked l;
    app.gpsValid = true;
    app.lat = lat;
    app.lng = lng;
  }
  acquireStartMs = millis();
}

void sleepFor(uint32_t durationMs) {
  uint8_t msg[16];
  const size_t n = buildUbxBackupRequest(durationMs, msg);
  Serial2.write(msg, n);
  Serial2.flush();
}

static void finishAcquire(uint32_t nowMs) {
  acquiring = false;
  // The receiver wakes itself after GPS_RECHECK_S; start listening again then.
  sleepFor(GPS_RECHECK_S * 1000UL);
  nextAcquireMs = nowMs + GPS_RECHECK_S * 1000UL;
}

void poll(uint32_t nowMs) {
  if (!acquiring) {
    if (static_cast<int32_t>(nowMs - nextAcquireMs) < 0) return;
    acquiring = true;
    acquireStartMs = nowMs;
  }

  while (Serial2.available() > 0) parser.encode(static_cast<char>(Serial2.read()));

  if (parser.location.isValid() && parser.location.isUpdated() && parser.location.age() < 2000) {
    const double lat = parser.location.lat();
    const double lng = parser.location.lng();
    bool moved;
    {
      Locked l;
      moved = !app.gpsValid ||
              distanceMeters(app.lat, app.lng, lat, lng) > GPS_MOVE_THRESHOLD_M;
      if (moved) {
        app.gpsValid = true;
        app.lat = lat;
        app.lng = lng;
      }
    }
    if (moved) storage::saveGps(lat, lng);
    finishAcquire(nowMs);
    return;
  }

  // No fix in time (or no module at all): keep the last saved fix; retry tomorrow.
  if (nowMs - acquireStartMs >= GPS_FIX_TIMEOUT_S * 1000UL) finishAcquire(nowMs);
}

}  // namespace hs::gps
