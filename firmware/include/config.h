// Every firmware tunable lives here (CLAUDE.md working rule 5). Values come
// from CLAUDE.md section 5 and docs/ERROR_HANDLING.md sections 5 and 6.
#pragma once

#include <stdint.h>

namespace hs {

constexpr const char* FIRMWARE_VERSION = "0.2.0";

// Pins (docs/hardware/NOTES.md, Pinout). The board prints them as D27, D34, D25, D26 and D2
// (same numbers); GPIO 0 is the BOOT button. Not the pins printed RX2/TX2 (GPIO 16/17).
constexpr uint8_t PIN_FLOW = 27;
constexpr uint8_t PIN_BATTERY_ADC = 34;
constexpr uint8_t PIN_GPS_RX = 25;
constexpr uint8_t PIN_GPS_TX = 26;
constexpr uint8_t PIN_WIFI_RESET = 0;
constexpr uint8_t PIN_STATUS_LED = 2;
constexpr uint32_t GPS_BAUD = 9600;

// Flow sensing and classification (L/min)
constexpr uint32_t FLOW_WINDOW_S = 5;
constexpr float PULSES_PER_LPM = 7.5f;
constexpr float FLOW_RATE_MAX = 40.0f;
constexpr float STARTER_LOW_FLOW_CUTOFF = 0.2f;
constexpr float STARTER_NORMAL_FLOW_CUTOFF = 2.0f;
constexpr float FLOW_HYSTERESIS = 0.1f;

// Upload rules A/B/C
constexpr uint32_t STATUS_CONFIRM_S = 3;
constexpr uint32_t STATUS_MIN_INTERVAL_S = 10;
constexpr uint32_t HEARTBEAT_S = 60;
constexpr float RATE_REPORT_DELTA_PCT = 15.0f;
constexpr float RATE_REPORT_MIN_ABS = 0.3f;
constexpr uint32_t RATE_REPORT_MIN_INTERVAL_S = 30;

// Network, retries and registration
constexpr uint32_t HTTP_TIMEOUT_S = 15;
constexpr uint32_t TLS_HANDSHAKE_TIMEOUT_S = 30;  // the core's default is 120 s
constexpr uint32_t BACKOFF_MIN_S = 5;
constexpr uint32_t BACKOFF_MAX_S = 300;
constexpr uint32_t REAUTH_FAIL_BACKOFF_S = 900;
constexpr uint32_t REGISTER_BLOCKED_RETRY_S = 3600;
constexpr uint32_t REGISTER_ACTIVE_RETRY_S = 240;

// Wi-Fi setup
constexpr uint32_t WIFI_CONNECT_TIMEOUT_S = 30;
constexpr uint32_t WIFI_RESET_HOLD_S = 5;
constexpr uint32_t PORTAL_TIMEOUT_S = 600;
constexpr const char* HOTSPOT_PREFIX = "HydroSense-";

// GPS
constexpr uint32_t GPS_FIX_TIMEOUT_S = 300;
constexpr uint32_t GPS_RECHECK_S = 86400;
constexpr uint32_t GPS_NO_FIX_RETRY_S = 3600;  // no fix saved yet: try hourly, not daily
constexpr float GPS_MOVE_THRESHOLD_M = 30.0f;

// Battery (2S pack through a 30k/10k divider)
constexpr uint8_t BATTERY_SERIES_CELLS = 2;
constexpr float BATTERY_DIVIDER_RATIO = 0.25f;
constexpr uint8_t BATTERY_ADC_SAMPLES = 16;
constexpr float BATTERY_CALIBRATION = 1.0f;  // Set against a multimeter (NOTES.md item 3).
constexpr float CELL_EMPTY_V = 3.3f;
constexpr float CELL_SPAN_V = 0.9f;
constexpr float CELL_PLAUSIBLE_MIN_V = 2.5f;
constexpr float CELL_PLAUSIBLE_MAX_V = 4.35f;

// Low-voltage protection (CLAUDE.md section 5 rule 8)
constexpr float LOW_VOLTAGE_SLEEP_CELL_V = 3.4f;
constexpr float LOW_VOLTAGE_RESUME_CELL_V = 3.6f;
constexpr uint8_t LOW_VOLTAGE_CONFIRM_READINGS = 3;
constexpr uint32_t LOW_VOLTAGE_CHECK_S = 1800;

// Power
constexpr uint32_t CPU_FREQ_MHZ = 80;

// Housekeeping
constexpr uint32_t BATTERY_READ_S = 60;           // also feeds the low-voltage guard
constexpr uint32_t NETWORK_STALL_RESTART_S = 120;  // software watchdog for the network task
constexpr uint32_t WIFI_LOST_RESTART_S = 300;      // Wi-Fi down this long (outside the portal)
constexpr uint32_t NO_RESPONSE_RESTART_S = 900;    // registered and online, but no HTTP reply

static_assert(HEARTBEAT_S < 90, "Heartbeat must stay under 90 s so the 3 min offline limit holds");
static_assert(TLS_HANDSHAKE_TIMEOUT_S + HTTP_TIMEOUT_S < NETWORK_STALL_RESTART_S,
              "A slow upload must not trip the stall restart");
static_assert(NO_RESPONSE_RESTART_S >= 2 * BACKOFF_MAX_S, "Allow several retries before restarting");
static_assert(STARTER_LOW_FLOW_CUTOFF < STARTER_NORMAL_FLOW_CUTOFF, "Cutoffs out of order");
static_assert(LOW_VOLTAGE_SLEEP_CELL_V < LOW_VOLTAGE_RESUME_CELL_V, "Sleep needs hysteresis");
static_assert(BACKOFF_MIN_S < BACKOFF_MAX_S, "Backoff range inverted");

}  // namespace hs
