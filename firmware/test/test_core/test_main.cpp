// Native unit tests for the pure firmware logic (Phase 4).
// Run: npm run fw:test   (or: pio test -e native, with a host g++ on PATH)
#include <string.h>
#include <unity.h>

#include "config.h"
#include "flow.h"
#include "misc.h"
#include "power.h"
#include "protocol.h"
#include "retry.h"
#include "scheduler.h"

using namespace hs;

void setUp() {}
void tearDown() {}

// ---------- pulse counting (fake counter) and the 5 s window ----------

struct FakeCounter {
  uint32_t value = 0;
  void pulse(uint32_t n) { value += n; }
};

static void test_counter_delta_survives_wraparound() {
  FakeCounter c;
  c.value = 0xFFFFFFF0u;
  uint32_t prev = c.value;
  c.pulse(32);  // wraps past zero
  TEST_ASSERT_EQUAL_UINT32(32, counterDelta(c.value, prev));
}

static void test_window_converts_pulses_to_lpm() {
  FlowWindow w;
  for (int i = 0; i < 5; i++) w.push(75);  // 75 Hz = 10 L/min
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 10.0f, w.rateLpm());
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 75.0f, w.pulseHz());
  w.push(0);  // the oldest second drops out
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 8.0f, w.rateLpm());
}

static void test_window_clamps_spikes() {
  FlowWindow w;
  for (int i = 0; i < 5; i++) w.push(10000);
  TEST_ASSERT_EQUAL_FLOAT(FLOW_RATE_MAX, w.rateLpm());
}

static void test_window_does_not_chatter_at_one_pulse_per_second() {
  // 1 and 2 pulses per second alternate around the 0.2 L/min cutoff (0.187 to
  // 0.213 L/min over 5 s). The status must settle and then stay put.
  FlowWindow w;
  Status s = Status::Unknown;
  int changes = 0;
  for (int t = 0; t < 120; t++) {
    w.push(t % 2 == 0 ? 1 : 2);
    if (t < 5) continue;
    Status next = classify(w.rateLpm(), s, 0.2f, 2.0f);
    if (s != Status::Unknown && next != s) changes++;
    s = next;
  }
  TEST_ASSERT_LESS_OR_EQUAL(1, changes);
}

// ---------- classification and hysteresis ----------

static void test_classify_starter_cutoffs() {
  TEST_ASSERT_EQUAL(Status::None, classify(0.1f, Status::Unknown, 0.2f, 2.0f));
  TEST_ASSERT_EQUAL(Status::Low, classify(1.0f, Status::Unknown, 0.2f, 2.0f));
  TEST_ASSERT_EQUAL(Status::Low, classify(2.0f, Status::Unknown, 0.2f, 2.0f));
  TEST_ASSERT_EQUAL(Status::Normal, classify(2.05f, Status::Unknown, 0.2f, 2.0f));
}

static void test_classify_hysteresis() {
  // Normal -> Low exactly at the cutoff; Low -> Normal only above cutoff + 0.1.
  TEST_ASSERT_EQUAL(Status::Low, classify(2.0f, Status::Normal, 0.2f, 2.0f));
  TEST_ASSERT_EQUAL(Status::Low, classify(2.05f, Status::Low, 0.2f, 2.0f));
  TEST_ASSERT_EQUAL(Status::Normal, classify(2.15f, Status::Low, 0.2f, 2.0f));
  // No Flow needs 0.3 to leave; Low drops to No below 0.2.
  TEST_ASSERT_EQUAL(Status::None, classify(0.25f, Status::None, 0.2f, 2.0f));
  TEST_ASSERT_EQUAL(Status::Low, classify(0.35f, Status::None, 0.2f, 2.0f));
  TEST_ASSERT_EQUAL(Status::None, classify(0.19f, Status::Low, 0.2f, 2.0f));
}

// ---------- upload rules A/B/C ----------

struct Run {
  UploadScheduler s;
  Trigger at(uint32_t t, Status st, float rate) { return s.tick(t, st, rate).trigger; }
};

static void test_first_reading_uploads_immediately() {
  Run r;
  TEST_ASSERT_EQUAL(Trigger::StatusChange, r.at(0, Status::Normal, 10));
  TEST_ASSERT_EQUAL(Trigger::None, r.at(1, Status::Normal, 10));
}

static void test_status_change_needs_3_s_confirmation() {
  Run r;
  r.at(0, Status::Normal, 10);
  for (uint32_t t = 20; t < 23; t++) TEST_ASSERT_EQUAL(Trigger::None, r.at(t, Status::Low, 1));
  UploadDecision d = r.s.tick(23, Status::Low, 1);
  TEST_ASSERT_EQUAL(Trigger::StatusChange, d.trigger);
  TEST_ASSERT_EQUAL(Status::Low, d.status);
}

static void test_a_blip_shorter_than_confirmation_sends_nothing() {
  Run r;
  r.at(0, Status::Normal, 10);
  r.at(20, Status::Low, 1);
  r.at(21, Status::Low, 1);
  TEST_ASSERT_EQUAL(Trigger::None, r.at(22, Status::Normal, 10));
  TEST_ASSERT_EQUAL(Status::Normal, r.s.confirmed());
}

static void test_status_uploads_are_10_s_apart() {
  Run r;
  r.at(0, Status::Normal, 10);
  r.at(1, Status::Low, 1);
  r.at(2, Status::Low, 1);
  r.at(3, Status::Low, 1);
  r.at(4, Status::Low, 1);  // confirmed at 4 s but only 4 s after the last status upload
  TEST_ASSERT_EQUAL(Status::Normal, r.s.confirmed());
  for (uint32_t t = 5; t < 10; t++) r.at(t, Status::Low, 1);
  TEST_ASSERT_EQUAL(Trigger::StatusChange, r.at(10, Status::Low, 1));
}

static void test_rate_change_needs_15_pct_and_0_3_lpm_and_10_s() {
  Run r;
  r.at(0, Status::Normal, 10);
  TEST_ASSERT_EQUAL(Trigger::None, r.at(9, Status::Normal, 12));  // 20 % but < 10 s
  TEST_ASSERT_EQUAL(Trigger::RateChange, r.at(10, Status::Normal, 12));
  TEST_ASSERT_EQUAL(Trigger::None, r.at(20, Status::Normal, 13));  // 8 % only (heartbeat not due)

  Run low;
  low.at(0, Status::Low, 0.5f);
  TEST_ASSERT_EQUAL(Trigger::None, low.at(20, Status::Low, 0.7f));  // 40 % but 0.2 L/min
}

static void test_rate_change_waits_while_a_status_is_pending() {
  Run r;
  r.at(0, Status::Normal, 10);
  TEST_ASSERT_EQUAL(Trigger::None, r.at(20, Status::Low, 1.2f));  // big drop, status pending
  TEST_ASSERT_EQUAL(Trigger::None, r.at(21, Status::Low, 1.2f));
  TEST_ASSERT_EQUAL(Trigger::None, r.at(22, Status::Low, 1.2f));
  TEST_ASSERT_EQUAL(Trigger::StatusChange, r.at(23, Status::Low, 1.2f));
}

static void test_heartbeat_every_30_s_when_quiet() {
  Run r;
  r.at(0, Status::Normal, 10);
  TEST_ASSERT_EQUAL(Trigger::None, r.at(29, Status::Normal, 10));
  TEST_ASSERT_EQUAL(Trigger::Heartbeat, r.at(30, Status::Normal, 10));
  TEST_ASSERT_EQUAL(Trigger::None, r.at(31, Status::Normal, 10));
  TEST_ASSERT_EQUAL(Trigger::Heartbeat, r.at(60, Status::Normal, 10));
}

static void test_server_pace_is_clamped() {
  Run r;
  r.s.setPace(1, 1000);  // a bad reply can neither make it spam nor go quiet
  TEST_ASSERT_EQUAL_UINT32(HEARTBEAT_MIN_S, r.s.heartbeatS());
  r.at(0, Status::Normal, 10);
  TEST_ASSERT_EQUAL(Trigger::None, r.at(HEARTBEAT_MIN_S - 1, Status::Normal, 10));
  TEST_ASSERT_EQUAL(Trigger::Heartbeat, r.at(HEARTBEAT_MIN_S, Status::Normal, 10));
  r.s.setPace(500, 10);
  TEST_ASSERT_EQUAL_UINT32(HEARTBEAT_MAX_S, r.s.heartbeatS());

  Pace p;
  const char ok[] = "{\"ok\":true,\"heartbeatS\":30,\"rateMinIntervalS\":10}";
  TEST_ASSERT_TRUE(parsePace(ok, strlen(ok), p));
  TEST_ASSERT_EQUAL_UINT32(30, p.heartbeatS);
  const char old[] = "{\"ok\":true,\"lowFlowCutoff\":0.2}";
  TEST_ASSERT_FALSE(parsePace(old, strlen(old), p));
}

static void test_reconnect_uploads_current_state() {
  Run r;
  r.at(0, Status::Normal, 10);
  r.s.requestImmediate();
  TEST_ASSERT_EQUAL(Trigger::StatusChange, r.at(5, Status::Normal, 10));
}

// ---------- battery and low-voltage protection ----------

static void test_battery_percent_2s_and_1s() {
  TEST_ASSERT_EQUAL_UINT8(0, batteryPercent(6.6f, 2));
  TEST_ASSERT_EQUAL_UINT8(50, batteryPercent(7.5f, 2));
  TEST_ASSERT_EQUAL_UINT8(100, batteryPercent(8.4f, 2));
  TEST_ASSERT_EQUAL_UINT8(100, batteryPercent(9.0f, 2));
  TEST_ASSERT_EQUAL_UINT8(50, batteryPercent(3.75f, 1));
  TEST_ASSERT_EQUAL_UINT8(0, batteryPercent(3.0f, 1));
}

static void test_divider_and_battery_fault() {
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 8.4f, packVoltageFromMv(2100));
  TEST_ASSERT_TRUE(batteryPlausible(7.4f));
  TEST_ASSERT_FALSE(batteryPlausible(0.0f));   // GPIO 34 on ground, as drawn
  TEST_ASSERT_FALSE(batteryPlausible(12.0f));  // divider disconnected
  TEST_ASSERT_TRUE(batteryPlausible(3.7f, 1));
}

static void test_low_voltage_sleep_needs_3_readings() {
  LowVoltageGuard g;
  TEST_ASSERT_FALSE(g.update(6.7f, false));
  TEST_ASSERT_FALSE(g.update(6.7f, false));
  TEST_ASSERT_TRUE(g.update(6.7f, false));

  LowVoltageGuard sag;  // one recovered reading resets the count
  sag.update(6.7f, false);
  sag.update(6.7f, false);
  sag.update(7.0f, false);
  TEST_ASSERT_FALSE(sag.update(6.7f, false));
}

static void test_low_voltage_never_sleeps_on_fault_and_resumes_higher() {
  LowVoltageGuard g;
  for (int i = 0; i < 5; i++) TEST_ASSERT_FALSE(g.update(6.7f, true));
  for (int i = 0; i < 5; i++) TEST_ASSERT_FALSE(g.update(0.0f, false));  // implausible
  TEST_ASSERT_FALSE(canResume(7.0f, false));
  TEST_ASSERT_TRUE(canResume(7.2f, false));
  TEST_ASSERT_TRUE(canResume(0.0f, true));
}

// ---------- retries ----------

static void test_backoff_doubles_to_5_min() {
  Backoff b;
  const uint32_t expected[] = {5, 10, 20, 40, 80, 160, 300, 300};
  for (uint32_t e : expected) TEST_ASSERT_EQUAL_UINT32(e, b.next());
  b.reset();
  TEST_ASSERT_EQUAL_UINT32(5, b.next());
}

static void test_retry_timings_for_409_403_429() {
  TEST_ASSERT_EQUAL(Action::RetryAfter, reactToRegister(409).action);
  TEST_ASSERT_EQUAL_UINT32(REGISTER_ACTIVE_RETRY_S, reactToRegister(409).delayS);
  TEST_ASSERT_EQUAL_UINT32(240, reactToRegister(409).delayS);
  TEST_ASSERT_EQUAL_UINT32(3600, reactToRegister(403).delayS);
  TEST_ASSERT_EQUAL_UINT32(3600, reactToRegister(429).delayS);
  TEST_ASSERT_EQUAL_UINT32(3600, reactToRegister(401).delayS);
  TEST_ASSERT_EQUAL(Action::Backoff, reactToRegister(503).action);
  TEST_ASSERT_EQUAL(Action::Backoff, reactToRegister(0).action);
  TEST_ASSERT_EQUAL(Action::Ok, reactToRegister(200).action);
}

static void test_ingest_reactions() {
  TEST_ASSERT_EQUAL(Action::Ok, reactToIngest(200).action);
  TEST_ASSERT_EQUAL(Action::Reregister, reactToIngest(401).action);
  TEST_ASSERT_EQUAL(Action::Drop, reactToIngest(400).action);
  TEST_ASSERT_EQUAL(Action::Backoff, reactToIngest(500).action);
  TEST_ASSERT_EQUAL(Action::Backoff, reactToIngest(0).action);
}

// ---------- network watchdog ----------

static const uint32_t MIN_MS = 60000;

static void test_watchdog_restarts_after_5_min_without_wifi() {
  NetWatchdog w;
  TEST_ASSERT_EQUAL(Stuck::No, w.check(0, true, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(1000, false, false, true));  // Wi-Fi lost at 1 s
  TEST_ASSERT_EQUAL(Stuck::No, w.check(1000 + 5 * MIN_MS - 1, false, false, true));
  TEST_ASSERT_EQUAL(Stuck::WifiLost, w.check(1000 + 5 * MIN_MS, false, false, true));
}

static void test_watchdog_ignores_the_portal_and_short_drops() {
  NetWatchdog w;
  // Setup portal open for 20 min: the portal's own timeout handles it.
  TEST_ASSERT_EQUAL(Stuck::No, w.check(0, false, true, false));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(20 * MIN_MS, false, true, false));
  // Two 4-minute drops with a reconnect between them never add up.
  const uint32_t t = 30 * MIN_MS;
  TEST_ASSERT_EQUAL(Stuck::No, w.check(t, false, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(t + 4 * MIN_MS, false, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(t + 4 * MIN_MS + 1000, true, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(t + 4 * MIN_MS + 2000, false, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(t + 8 * MIN_MS + 2000, false, false, true));
}

static void test_watchdog_restarts_after_15_min_without_any_reply() {
  NetWatchdog w;
  TEST_ASSERT_EQUAL(Stuck::No, w.check(0, true, false, true));
  w.noteResponse(10 * MIN_MS);  // any HTTP status counts, even an error
  TEST_ASSERT_EQUAL(Stuck::No, w.check(25 * MIN_MS - 1, true, false, true));
  TEST_ASSERT_EQUAL(Stuck::NoResponse, w.check(25 * MIN_MS, true, false, true));
}

static void test_watchdog_counts_silence_only_while_online_and_registered() {
  NetWatchdog w;
  // Not registered (for example waiting 1 h after a 403): never a restart.
  TEST_ASSERT_EQUAL(Stuck::No, w.check(0, true, false, false));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(60 * MIN_MS, true, false, false));
  // Registered at 60 min: the silence clock starts then, not at boot.
  TEST_ASSERT_EQUAL(Stuck::No, w.check(60 * MIN_MS, true, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(74 * MIN_MS, true, false, true));
  // A 1-minute Wi-Fi drop restarts the clock too.
  TEST_ASSERT_EQUAL(Stuck::No, w.check(74 * MIN_MS + 1000, false, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(75 * MIN_MS, true, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(90 * MIN_MS - 1, true, false, true));
  TEST_ASSERT_EQUAL(Stuck::NoResponse, w.check(90 * MIN_MS, true, false, true));
}

static void test_watchdog_survives_millis_wraparound() {
  NetWatchdog w;
  const uint32_t nearWrap = 0xFFFFFFFFu - MIN_MS;
  TEST_ASSERT_EQUAL(Stuck::No, w.check(nearWrap, false, false, true));
  TEST_ASSERT_EQUAL(Stuck::No, w.check(nearWrap + 4 * MIN_MS, false, false, true));
  TEST_ASSERT_EQUAL(Stuck::WifiLost, w.check(nearWrap + 5 * MIN_MS, false, false, true));
}

// ---------- small helpers ----------

static void test_device_id_from_mac() {
  char id[13];
  TEST_ASSERT_TRUE(deviceIdFromMac("a1:b2:c3:d4:e5:f6", id));
  TEST_ASSERT_EQUAL_STRING("A1B2C3D4E5F6", id);
  TEST_ASSERT_FALSE(deviceIdFromMac("A1:B2:C3", id));
  TEST_ASSERT_FALSE(deviceIdFromMac("G1:B2:C3:D4:E5:F6", id));
}

static void test_distance_for_gps_move_check() {
  TEST_ASSERT_FLOAT_WITHIN(1.0f, 0.0f, (float)distanceMeters(16.04, 120.33, 16.04, 120.33));
  // 0.0003 degrees of latitude is about 33 m: just over the 30 m threshold.
  const double d = distanceMeters(16.04, 120.33, 16.0403, 120.33);
  TEST_ASSERT_TRUE(d > GPS_MOVE_THRESHOLD_M && d < 40);
}

static void test_ubx_backup_request_matches_known_bytes() {
  // Known-good RXM-PMREQ "backup, infinite": B5 62 02 41 08 00 00000000 02000000 4D 3B.
  uint8_t m[16];
  TEST_ASSERT_EQUAL(16, buildUbxBackupRequest(0, m));
  const uint8_t expected[16] = {0xB5, 0x62, 0x02, 0x41, 0x08, 0x00, 0, 0,
                                0,    0,    0x02, 0,    0,    0,    0x4D, 0x3B};
  TEST_ASSERT_EQUAL_UINT8_ARRAY(expected, m, 16);

  buildUbxBackupRequest(86400000u, m);  // 24 h = 0x05265C00, little endian
  TEST_ASSERT_EQUAL_HEX8(0x00, m[6]);
  TEST_ASSERT_EQUAL_HEX8(0x5C, m[7]);
  TEST_ASSERT_EQUAL_HEX8(0x26, m[8]);
  TEST_ASSERT_EQUAL_HEX8(0x05, m[9]);
}

static void test_led_patterns() {
  TEST_ASSERT_TRUE(ledOn(LedMode::Connected, 1234));
  TEST_ASSERT_TRUE(ledOn(LedMode::Connecting, 100));
  TEST_ASSERT_FALSE(ledOn(LedMode::Connecting, 600));
  TEST_ASSERT_TRUE(ledOn(LedMode::Hotspot, 100));
  TEST_ASSERT_FALSE(ledOn(LedMode::Hotspot, 200));
  TEST_ASSERT_TRUE(ledOn(LedMode::Rejecting, 50));
  TEST_ASSERT_FALSE(ledOn(LedMode::Rejecting, 150));
  TEST_ASSERT_TRUE(ledOn(LedMode::Rejecting, 250));
  TEST_ASSERT_FALSE(ledOn(LedMode::Rejecting, 1500));
  TEST_ASSERT_FALSE(ledOn(LedMode::Off, 50));
}

// ---------- protocol bodies ----------

static void test_ingest_body_uses_protocol_field_names() {
  Reading r;
  r.status = Status::Normal;
  r.flowRate = 4.2f;
  r.pulseHz = 31.5f;
  r.batteryVoltage = 7.92f;
  r.gpsValid = true;
  r.lat = 16.04;
  r.lng = 120.33;
  r.rssi = -61;
  r.firmware = "1.0.0";
  r.trigger = Trigger::StatusChange;
  char buf[512];
  TEST_ASSERT_TRUE(buildIngestBody(r, buf, sizeof buf) > 0);
  TEST_ASSERT_EQUAL_STRING(
      "{\"flowStatus\":\"Normal Flow\",\"flowRate\":4.2,\"batteryVoltage\":7.92,"
      "\"batteryFault\":false,\"lat\":16.04,\"lng\":120.33,\"gpsValid\":true,\"rssi\":-61,"
      "\"firmware\":\"1.0.0\",\"resetReason\":null,\"trigger\":\"status_change\",\"heartbeatS\":30}",
      buf);
}

static void test_ingest_body_fault_no_gps_and_sleep() {
  Reading r;
  r.status = Status::None;
  r.batteryFault = true;
  r.firmware = "1.0.0";
  r.resetReason = "brownout";
  r.lowVoltageSleep = true;
  char buf[512];
  buildIngestBody(r, buf, sizeof buf);
  TEST_ASSERT_NULL(strstr(buf, "batteryVoltage"));
  TEST_ASSERT_NULL(strstr(buf, "\"lat\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"gpsValid\":false"));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"resetReason\":\"brownout\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"lowVoltageSleep\":true"));
  char tiny[16];
  TEST_ASSERT_EQUAL(0, buildIngestBody(r, tiny, sizeof tiny));
}

static void test_parse_server_responses() {
  Cutoffs c;
  const char* ok = "{\"ok\":true,\"lowFlowCutoff\":0.5,\"normalFlowCutoff\":6}";
  TEST_ASSERT_TRUE(parseCutoffs(ok, strlen(ok), c));
  TEST_ASSERT_EQUAL_FLOAT(0.5f, c.low);
  TEST_ASSERT_EQUAL_FLOAT(6.0f, c.normal);
  const char* bad = "{\"ok\":true,\"lowFlowCutoff\":3,\"normalFlowCutoff\":2}";
  TEST_ASSERT_FALSE(parseCutoffs(bad, strlen(bad), c));
  TEST_ASSERT_EQUAL_FLOAT(0.5f, c.low);  // unchanged

  char token[64];
  const char* reg = "{\"ok\":true,\"token\":\"abc_DEF-123\",\"lowFlowCutoff\":0.2}";
  TEST_ASSERT_TRUE(parseToken(reg, strlen(reg), token, sizeof token));
  TEST_ASSERT_EQUAL_STRING("abc_DEF-123", token);

  char code[32];
  const char* err = "{\"ok\":false,\"code\":\"DEVICE_REMOVED\",\"message\":\"x\"}";
  parseErrorCode(err, strlen(err), code, sizeof code);
  TEST_ASSERT_EQUAL_STRING("DEVICE_REMOVED", code);
  parseErrorCode("not json", 8, code, sizeof code);
  TEST_ASSERT_EQUAL_STRING("", code);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_counter_delta_survives_wraparound);
  RUN_TEST(test_window_converts_pulses_to_lpm);
  RUN_TEST(test_window_clamps_spikes);
  RUN_TEST(test_window_does_not_chatter_at_one_pulse_per_second);
  RUN_TEST(test_classify_starter_cutoffs);
  RUN_TEST(test_classify_hysteresis);
  RUN_TEST(test_first_reading_uploads_immediately);
  RUN_TEST(test_status_change_needs_3_s_confirmation);
  RUN_TEST(test_a_blip_shorter_than_confirmation_sends_nothing);
  RUN_TEST(test_status_uploads_are_10_s_apart);
  RUN_TEST(test_rate_change_needs_15_pct_and_0_3_lpm_and_10_s);
  RUN_TEST(test_rate_change_waits_while_a_status_is_pending);
  RUN_TEST(test_heartbeat_every_30_s_when_quiet);
  RUN_TEST(test_server_pace_is_clamped);
  RUN_TEST(test_reconnect_uploads_current_state);
  RUN_TEST(test_battery_percent_2s_and_1s);
  RUN_TEST(test_divider_and_battery_fault);
  RUN_TEST(test_low_voltage_sleep_needs_3_readings);
  RUN_TEST(test_low_voltage_never_sleeps_on_fault_and_resumes_higher);
  RUN_TEST(test_backoff_doubles_to_5_min);
  RUN_TEST(test_retry_timings_for_409_403_429);
  RUN_TEST(test_ingest_reactions);
  RUN_TEST(test_watchdog_restarts_after_5_min_without_wifi);
  RUN_TEST(test_watchdog_ignores_the_portal_and_short_drops);
  RUN_TEST(test_watchdog_restarts_after_15_min_without_any_reply);
  RUN_TEST(test_watchdog_counts_silence_only_while_online_and_registered);
  RUN_TEST(test_watchdog_survives_millis_wraparound);
  RUN_TEST(test_device_id_from_mac);
  RUN_TEST(test_distance_for_gps_move_check);
  RUN_TEST(test_ubx_backup_request_matches_known_bytes);
  RUN_TEST(test_led_patterns);
  RUN_TEST(test_ingest_body_uses_protocol_field_names);
  RUN_TEST(test_ingest_body_fault_no_gps_and_sleep);
  RUN_TEST(test_parse_server_responses);
  return UNITY_END();
}
