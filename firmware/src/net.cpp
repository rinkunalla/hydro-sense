#include "net.h"

#include <Arduino.h>
#include <HTTPClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WiFiManager.h>
#include <time.h>

#include "app_state.h"
#include "config.h"
#include "google_roots.h"
#include "gps.h"
#include "power.h"
#include "retry.h"
#include "storage.h"

#if __has_include("secrets.h")
#include "secrets.h"
#else
#warning "firmware/include/secrets.h is missing: building with secrets.h.example (cannot register)"
#include "secrets.h.example"
#endif

namespace hs::net {

static WiFiManager portal;
static WiFiClientSecure tls;
static HTTPClient http;
static char token[96] = {};
static char apName[24] = {};
static bool timeSynced = false;
static bool wasConnected = false;
static uint32_t nextAttemptMs = 0;
static uint32_t registerAfterMs = 0;
static uint32_t rejectingUntilMs = 0;
static Backoff backoff;
static NetWatchdog watchdog;

static bool due(uint32_t now, uint32_t at) { return static_cast<int32_t>(now - at) >= 0; }

static void setLed(LedMode m) {
  Locked l;
  app.led = m;
}

/** POSTs a JSON body; returns the HTTP status (0 on network/TLS error) and the response. */
static int post(const char* path, const char* body, String& response, bool withToken) {
  String url = String(API_BASE_URL) + path;
  if (!http.begin(tls, url)) {
    Serial.println("HTTP error: bad URL");
    return 0;
  }
  http.addHeader("Content-Type", "application/json");
  if (withToken) {
    http.addHeader("X-Device-Id", app.deviceId);
    http.addHeader("Authorization", String("Bearer ") + token);
  } else {
    http.addHeader("X-Provisioning-Key", PROVISIONING_KEY);
  }
  const int code = http.POST(String(body));
  if (code > 0) {
    watchdog.noteResponse(millis());
    response = http.getString();
  } else {
    response = String();
    Serial.printf("HTTP error %d: %s\n", code, HTTPClient::errorToString(code).c_str());
  }
  http.end();  // with setReuse(true) the TLS connection stays open (keep-alive)
  return code > 0 ? code : 0;
}

/** One line per upload on the serial monitor (local only; nothing here is sent anywhere). */
static void logUpload(const Reading& r, int code) {
  char battery[32];
  if (r.batteryFault) {
    snprintf(battery, sizeof battery, "no reading (%.2f V)", r.batteryVoltage);
  } else {
    snprintf(battery, sizeof battery, "%.2f V", r.batteryVoltage);
  }
  const char* status = statusName(r.status);
  const char* trigger = triggerName(r.trigger);
  Serial.printf("Upload %s: HTTP %d | %s %.2f L/min (%.2f pulses/s) | battery %s | GPS %s | RSSI %d dBm | heap %u\n",
                trigger ? trigger : "?", code, status ? status : "?", r.flowRate, r.pulseHz, battery,
                r.gpsValid ? "fix saved" : "no fix yet", r.rssi,
                static_cast<unsigned>(ESP.getFreeHeap()));
}

static void applyCutoffs(const String& response) {
  Pace pace;
  if (parsePace(response.c_str(), response.length(), pace)) {
    Locked l;
    app.pace = pace;
  }
  // The sensor before the cutoffs: a new sensor type arrives with its own
  // starter cutoffs in the same reply (D69). Older servers send no sensor.
  Sensor sensor;
  if (parseSensor(response.c_str(), response.length(), sensor)) {
    storage::saveSensorIfChanged(sensor);
    Locked l;
    app.sensor = sensor;
  }
  Cutoffs c;
  if (!parseCutoffs(response.c_str(), response.length(), c)) return;
  storage::saveCutoffsIfChanged(c);
  Locked l;
  app.cutoffs = c;
}

/** Returns true when a token is held afterwards. */
static bool registerDevice(uint32_t now) {
  char body[96];
  buildRegisterBody(app.deviceId, FIRMWARE_VERSION, body, sizeof body);
  String response;
  const int code = post("/registerDevice", body, response, false);
  const Reaction r = reactToRegister(code);
  if (r.action == Action::Ok && parseToken(response.c_str(), response.length(), token, sizeof token)) {
    storage::saveToken(token);
    applyCutoffs(response);
    backoff.reset();
    Serial.println("Registered");
    return true;
  }
  char err[32];
  parseErrorCode(response.c_str(), response.length(), err, sizeof err);
  Serial.printf("Register failed: HTTP %d %s\n", code, err);
  if (r.action == Action::RetryAfter) {
    registerAfterMs = now + r.delayS * 1000UL;
    rejectingUntilMs = registerAfterMs;
  } else {
    registerAfterMs = now + backoff.next() * 1000UL;
  }
  return false;
}

static void sendOutbox(uint32_t now) {
  Reading r;
  uint32_t seq;
  {
    Locked l;
    if (!app.outboxFull) return;
    r = app.outbox;
    seq = app.outboxSeq;
  }
  char body[384];
  if (buildIngestBody(r, body, sizeof body) == 0) return;

  String response;
  int code = post("/deviceIngest", body, response, true);
  Reaction reaction = reactToIngest(code);
  if (reaction.action == Action::Reregister) {
    token[0] = '\0';
    storage::clearToken();
    if (registerDevice(now)) {
      code = post("/deviceIngest", body, response, true);
      reaction = reactToIngest(code);
    } else {
      nextAttemptMs = now + REAUTH_FAIL_BACKOFF_S * 1000UL;
      Serial.printf("Re-registration failed: next try in %u s\n",
                    static_cast<unsigned>(REAUTH_FAIL_BACKOFF_S));
      return;
    }
  }

  logUpload(r, code);
  switch (reaction.action) {
    case Action::Ok:
      applyCutoffs(response);
      backoff.reset();
      setLed(LedMode::Connected);
      [[fallthrough]];
    case Action::Drop: {  // a rejected payload is not resent; the next window replaces it
      Locked l;
      if (app.outboxSeq == seq) app.outboxFull = false;
      if (reaction.action == Action::Ok && r.resetReason) app.resetReason[0] = '\0';
      if (reaction.action == Action::Drop) rejectingUntilMs = now + 3000;
      break;
    }
    default: {
      const uint32_t waitS = backoff.next();
      nextAttemptMs = now + waitS * 1000UL;
      Serial.printf("Upload failed: retrying in %u s\n", static_cast<unsigned>(waitS));
      break;
    }
  }
}

static void syncClock() {
  if (timeSynced) return;
  configTime(0, 0, "time.google.com", "pool.ntp.org");
  const uint32_t start = millis();
  while (time(nullptr) < 1700000000 && millis() - start < 10000) delay(200);
  timeSynced = time(nullptr) >= 1700000000;
}

/** Final upload, GPS backup, then deep sleep until the timer or a BOOT press. */
static void enterLowVoltageSleep() {
  const uint32_t start = millis();
  while (millis() - start < 20000) {
    {
      Locked l;
      if (!app.outboxFull) break;
    }
    if (WiFi.isConnected() && token[0]) sendOutbox(millis());
    delay(500);
  }
  gps::sleepFor(LOW_VOLTAGE_CHECK_S * 1000UL + 60000UL);
  Serial.println("Low-voltage sleep");
  Serial.flush();
  esp_sleep_enable_timer_wakeup(static_cast<uint64_t>(LOW_VOLTAGE_CHECK_S) * 1000000ULL);
  esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(PIN_WIFI_RESET), 0);
  esp_deep_sleep_start();
}

static void networkTask(void*) {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(true);  // modem sleep between uploads
  WiFi.setAutoReconnect(true);

  snprintf(apName, sizeof apName, "%s%s", HOTSPOT_PREFIX, app.deviceId + 8);
  static char idHtml[64];
  snprintf(idHtml, sizeof idHtml, "<p>Device ID: <b>%s</b></p>", app.deviceId);
  static WiFiManagerParameter idInfo(idHtml);
  portal.addParameter(&idInfo);
  portal.setTitle("Hydro Sense");
  portal.setConfigPortalBlocking(false);
  portal.setConnectTimeout(WIFI_CONNECT_TIMEOUT_S);
  portal.setConfigPortalTimeout(PORTAL_TIMEOUT_S);
  const bool connected = portal.autoConnect(apName);
  bool portalWasActive = !connected;

  tls.setCACert(GOOGLE_ROOTS_PEM);
  tls.setHandshakeTimeout(TLS_HANDSHAKE_TIMEOUT_S);
  http.setReuse(true);
  http.setTimeout(HTTP_TIMEOUT_S * 1000UL);
  if (storage::loadToken(token, sizeof token)) Serial.println("Token loaded from NVS");

  for (;;) {
    const uint32_t now = millis();
    {
      Locked l;
      app.networkAliveMs = now;
    }

    bool resetWifi, sleepNow;
    {
      Locked l;
      resetWifi = app.wifiResetRequested;
      sleepNow = app.sleepRequested;
    }
    if (resetWifi) {
      Serial.println("BOOT held: clearing Wi-Fi settings");
      portal.resetSettings();
      ESP.restart();
    }
    if (sleepNow) enterLowVoltageSleep();

    portal.process();
    const bool portalActive = portal.getConfigPortalActive();
    if (portalWasActive && !portalActive && !WiFi.isConnected()) {
      ESP.restart();  // portal timed out: reboot and retry the saved Wi-Fi
    }
    portalWasActive = portalActive;

    gps::poll(now);

    const bool online = WiFi.isConnected();
    if (online && !wasConnected) {
      Serial.printf("Wi-Fi connected (RSSI %d dBm)\n", WiFi.RSSI());
      Locked l;
      app.reconnected = true;  // Rule A: upload the current state at once
    } else if (!online && wasConnected) {
      Serial.println("Wi-Fi lost");
    }
    wasConnected = online;

    const Stuck stuck = watchdog.check(now, online, portalActive, token[0] != '\0');
    if (stuck != Stuck::No) {
      if (stuck == Stuck::WifiLost) {
        Serial.printf("Wi-Fi down for %u s: restarting\n", static_cast<unsigned>(WIFI_LOST_RESTART_S));
      } else {
        Serial.printf("No server response for %u s: restarting\n",
                      static_cast<unsigned>(NO_RESPONSE_RESTART_S));
      }
      Serial.flush();
      ESP.restart();
    }

    if (portalActive) {
      setLed(LedMode::Hotspot);
    } else if (!online) {
      setLed(LedMode::Connecting);
    } else {
      syncClock();
      if (!token[0] && due(now, registerAfterMs)) registerDevice(now);
      if (token[0] && due(now, nextAttemptMs)) sendOutbox(now);
      setLed(due(now, rejectingUntilMs) ? LedMode::Connected : LedMode::Rejecting);
    }
    delay(100);
  }
}

void start() { xTaskCreatePinnedToCore(networkTask, "net", 12288, nullptr, 1, nullptr, 0); }

}  // namespace hs::net
