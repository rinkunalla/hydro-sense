// State shared between the sampling, network and LED tasks. Every field is read
// and written under `lock`; the outbox holds only the latest upload (no queue).
#pragma once

#include <Arduino.h>

#include "misc.h"
#include "protocol.h"

namespace hs {

struct AppState {
  SemaphoreHandle_t lock = nullptr;

  char deviceId[13] = {};
  char resetReason[16] = {};  // sent once, then cleared

  // Sampling task -> network task
  bool outboxFull = false;
  Reading outbox;
  uint32_t outboxSeq = 0;
  bool sleepRequested = false;  // low-voltage protection
  bool wifiResetRequested = false;

  // Network task -> sampling task
  Cutoffs cutoffs;
  bool reconnected = false;  // upload the current state at once
  uint32_t networkAliveMs = 0;

  // GPS (network task writes, sampling task reads)
  bool gpsValid = false;
  double lat = 0;
  double lng = 0;

  LedMode led = LedMode::Connecting;
};

extern AppState app;

/** RAII lock for AppState. */
class Locked {
 public:
  Locked() { xSemaphoreTake(app.lock, portMAX_DELAY); }
  ~Locked() { xSemaphoreGive(app.lock); }
  Locked(const Locked&) = delete;
  Locked& operator=(const Locked&) = delete;
};

}  // namespace hs
