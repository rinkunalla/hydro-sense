// NVS (Preferences) storage. Writes happen only when a value changes, to spare flash.
#pragma once

#include <stddef.h>

#include "protocol.h"

namespace hs::storage {

void begin();

bool loadToken(char* out, size_t cap);
void saveToken(const char* token);
void clearToken();

Cutoffs loadCutoffs();
void saveCutoffsIfChanged(const Cutoffs& c);

/** The sensor from the last reply (D69); YF-S201 when none was saved. */
Sensor loadSensor();
void saveSensorIfChanged(const Sensor& s);

bool loadGps(double& lat, double& lng);
void saveGps(double lat, double lng);

}  // namespace hs::storage
