// Hydro Sense firmware entry point. Sampling (core 1) never waits on the network
// (core 0); the two tasks share only the latest reading through AppState.
#include <Arduino.h>
#include <WiFi.h>
#include <esp_system.h>
#include <esp_task_wdt.h>

#include "app_state.h"
#include "config.h"
#include "flow.h"
#include "gps.h"
#include "misc.h"
#include "net.h"
#include "power.h"
#include "scheduler.h"
#include "sensors.h"
#include "storage.h"

namespace hs {
AppState app;
}

using namespace hs;

// Survives deep sleep: set while the device is resting to protect the battery.
RTC_DATA_ATTR static bool lowVoltageSleeping = false;

static const char* abnormalResetReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_BROWNOUT:
      return "brownout";
    case ESP_RST_PANIC:
      return "panic";
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT:
      return "watchdog";
    default:
      return nullptr;
  }
}

/** Woken from low-voltage sleep by the timer: go back to sleep unless the pack recovered. */
static void checkLowVoltageWake() {
  if (!lowVoltageSleeping) return;
  if (esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_TIMER) {
    const sensors::Battery b = sensors::readBattery();
    if (!canResume(b.packV, b.fault)) {
      Serial.printf("Battery %.2f V: still low, sleeping again\n", b.packV);
      Serial.flush();
      esp_sleep_enable_timer_wakeup(static_cast<uint64_t>(LOW_VOLTAGE_CHECK_S) * 1000000ULL);
      esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(PIN_WIFI_RESET), 0);
      esp_deep_sleep_start();
    }
  }
  lowVoltageSleeping = false;  // recovered, or BOOT pressed for service
}

static void ledTask(void*) {
  pinMode(PIN_STATUS_LED, OUTPUT);
  for (;;) {
    LedMode m;
    {
      Locked l;
      m = app.led;
    }
    digitalWrite(PIN_STATUS_LED, ledOn(m, millis()) ? HIGH : LOW);
    delay(25);
  }
}

static void samplingTask(void*) {
  esp_task_wdt_add(nullptr);
  FlowWindow window;
  UploadScheduler scheduler;
  LowVoltageGuard guard;
  sensors::Battery battery = sensors::readBattery();
  uint32_t lastCount = sensors::pulseCount();
  uint32_t bootHeldS = 0;
  uint32_t seconds = 0;
  TickType_t wake = xTaskGetTickCount();

  for (;;) {
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(1000));
    esp_task_wdt_reset();
    seconds++;

    const uint32_t count = sensors::pulseCount();
    window.push(counterDelta(count, lastCount));
    lastCount = count;

    if (seconds % BATTERY_READ_S == 0) {
      battery = sensors::readBattery();
      if (guard.update(battery.packV, battery.fault)) {
        lowVoltageSleeping = true;
        Reading r;
        {
          Locked l;
          r = app.outbox;
        }
        r.status = scheduler.confirmed();
        r.flowRate = window.rateLpm();
        r.batteryVoltage = battery.packV;
        r.batteryFault = battery.fault;
        r.trigger = Trigger::Heartbeat;
        r.lowVoltageSleep = true;
        Locked l;
        app.outbox = r;
        app.outboxFull = true;
        app.outboxSeq++;
        app.sleepRequested = true;
      }
    }

    // BOOT held for WIFI_RESET_HOLD_S while running: clear Wi-Fi and open the portal.
    bootHeldS = digitalRead(PIN_WIFI_RESET) == LOW ? bootHeldS + 1 : 0;

    Cutoffs cut;
    Pace pace;
    bool reconnected;
    uint32_t aliveMs;
    {
      Locked l;
      cut = app.cutoffs;
      pace = app.pace;
      reconnected = app.reconnected;
      app.reconnected = false;
      aliveMs = app.networkAliveMs;
      if (bootHeldS >= WIFI_RESET_HOLD_S) app.wifiResetRequested = true;
    }
    if (millis() - aliveMs > NETWORK_STALL_RESTART_S * 1000UL) {
      Serial.println("Network task stalled: restarting");
      ESP.restart();
    }
    if (reconnected) scheduler.requestImmediate();
    scheduler.setPace(pace.heartbeatS, pace.rateMinIntervalS);

    const float rate = window.rateLpm();
    const Status classified = classify(rate, scheduler.confirmed(), cut.low, cut.normal);
    const UploadDecision d = scheduler.tick(seconds, classified, rate);
    if (d.trigger == Trigger::None) continue;
    if (d.trigger == Trigger::Heartbeat) battery = sensors::readBattery();

    Locked l;
    if (app.sleepRequested) continue;  // the sleep heartbeat is already queued
    Reading& r = app.outbox;
    r.status = d.status;
    r.flowRate = d.rateLpm;
    r.pulseHz = window.pulseHz();
    r.batteryVoltage = battery.packV;
    r.batteryFault = battery.fault;
    r.gpsValid = app.gpsValid;
    r.lat = app.lat;
    r.lng = app.lng;
    r.rssi = WiFi.RSSI();
    r.firmware = FIRMWARE_VERSION;
    r.resetReason = app.resetReason[0] ? app.resetReason : nullptr;
    r.trigger = d.trigger;
    r.lowVoltageSleep = false;
    r.heartbeatS = scheduler.heartbeatS();
    app.outboxFull = true;
    app.outboxSeq++;
  }
}

void setup() {
  setCpuFrequencyMhz(CPU_FREQ_MHZ);
  Serial.begin(115200);
  pinMode(PIN_WIFI_RESET, INPUT_PULLUP);
  sensors::begin();
  checkLowVoltageWake();

  app.lock = xSemaphoreCreateMutex();
  if (!deviceIdFromMac(WiFi.macAddress().c_str(), app.deviceId)) {
    strncpy(app.deviceId, "000000000000", sizeof app.deviceId);
  }
  if (const char* why = abnormalResetReason()) {
    strncpy(app.resetReason, why, sizeof app.resetReason - 1);
  }
  Serial.printf("\nHydro Sense %s  Device ID: %s\n", FIRMWARE_VERSION, app.deviceId);
  const sensors::Battery battery = sensors::readBattery();
  Serial.printf("Battery: %.2f V%s\n", battery.packV,
                battery.fault ? " (outside the plausible range: sent as no reading)" : "");

  storage::begin();
  app.cutoffs = storage::loadCutoffs();
  app.networkAliveMs = millis();
  gps::begin();

  xTaskCreatePinnedToCore(samplingTask, "sample", 4096, nullptr, 2, nullptr, 1);
  xTaskCreatePinnedToCore(ledTask, "led", 2048, nullptr, 1, nullptr, 1);
  net::start();
}

void loop() { vTaskDelete(nullptr); }  // all work runs in the tasks above
