#include "sensors.h"

#include <Arduino.h>

#include "config.h"
#include "power.h"

namespace hs::sensors {

static volatile uint32_t pulses = 0;

static void IRAM_ATTR onPulse() { pulses = pulses + 1; }

void begin() {
  // INPUT with the 4.7k/10k divider; INPUT_PULLUP only for an open-collector
  // sensor without its own pull-up.
  pinMode(PIN_FLOW, INPUT);
  attachInterrupt(digitalPinToInterrupt(PIN_FLOW), onPulse, FALLING);
  analogSetPinAttenuation(PIN_BATTERY_ADC, ADC_11db);
}

uint32_t pulseCount() { return pulses; }  // 32-bit reads are atomic on the ESP32

Battery readBattery() {
  uint32_t sum = 0;
  for (uint8_t i = 0; i < BATTERY_ADC_SAMPLES; i++) sum += analogReadMilliVolts(PIN_BATTERY_ADC);
  const float v = packVoltageFromMv(sum / BATTERY_ADC_SAMPLES);
  return {v, !batteryPlausible(v)};
}

}  // namespace hs::sensors
