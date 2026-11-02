#include <Arduino.h>

#include "config.h"

void setup() {
  Serial.begin(115200);
  Serial.printf("Hydro Sense firmware %s\n", hs::FIRMWARE_VERSION);
}

void loop() { delay(1000); }
