// Hardware sensors: YF-S201 pulse interrupt (GPIO 27) and the battery divider ADC (GPIO 34).
#pragma once

#include <stdint.h>

namespace hs::sensors {

void begin();

/** Free-running pulse count (wraps; use counterDelta). */
uint32_t pulseCount();

struct Battery {
  float packV;
  bool fault;  // divider disconnected or miswired
};

/** 16-sample average of the GPIO 34 midpoint, converted to pack volts. */
Battery readBattery();

}  // namespace hs::sensors
