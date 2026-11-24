// Every backend tunable lives here.

// Deployment
export const REGION = "asia-east1";
// Realtime Database for the live channel. Its location is fixed at creation;
// asia-southeast1 (Singapore) is the nearest Realtime Database location.
export const DATABASE_URL =
  "https://hydro-sense-dc836-default-rtdb.asia-southeast1.firebasedatabase.app";
export const MAX_INSTANCES = 2;
export const TIME_ZONE = "Asia/Manila";

// Device health and offline detection
// Upload pace the server hands to firmware 0.3.0+ in every reply, so it can be
// tuned without a reflash. Firmware clamps both to its own safe range.
export const DEVICE_HEARTBEAT_S = 20; // Offline 40 s after the last data
export const DEVICE_RATE_MIN_INTERVAL_S = 5; // smoother live chart; firmware floor is 5
/** A device that reports its heartbeat goes offline after this many missed (60 s at 30 s). */
export const OFFLINE_MISSED_HEARTBEATS = 2;
export const OFFLINE_AFTER_MIN_S = 40;
/** For firmware that does not report its heartbeat (0.2.0, 60 s heartbeats). */
export const OFFLINE_AFTER_S = 180;
export const HEARTBEAT_REPORTED_MIN_S = 10;
export const HEARTBEAT_REPORTED_MAX_S = 120;
// The offline alert goes as soon as the device counts as Offline: 60 s with
// nothing from it. The once-a-minute monitor makes that 1 to 2 min.
export const OFFLINE_ALERT_AFTER_S = 40;
// 30 min of readings at the 30 s heartbeat.
export const RECENT_VOLTAGES_CAP = 60;
export const BATTERY_SERIES_CELLS = 2;
export const BATTERY_CELL_EMPTY_V = 3.3;
export const BATTERY_CELL_SPAN_V = 0.9;
export const LOW_BATTERY_PERCENT = 20;
export const BATTERY_REARM_PERCENT = 30;
export const CHARGING_TREND_SAMPLES = 15;
/** batteryPercent is the MEDIAN of the newest readings: the ESP32's
 * battery reading dips now and then (7.63 V among 8.05 V readings, likely
 * taken while Wi-Fi transmits), and an average let one dip move the percent
 * and fake a "Charging" trend when it left the window. */
export const BATTERY_SMOOTH_SAMPLES = 9;
/** Rise between the medians of the oldest and newest CHARGING_TREND_SAMPLES. */
export const CHARGING_RISE_PER_CELL_V = 0.03;
export const CHARGING_FULL_PER_CELL_V = 4.15;

// Flow sensors (D69). Each device has one; the server sends its pulse factor,
// window and starter cutoffs in every reply (firmware 0.4.0 uses them).
// pulsesPerLpm: pulse frequency in Hz for 1 L/min (F = k x Q).
// The admin's own "Low flow below X L/min" stays inside userCutoffMin..Max
// (the sensor's reliable range). Mirrored in the website's validation.
export const SENSORS = {
  yf_s201: {
    label: "YF-S201",
    pulsesPerLpm: 7.5,
    flowWindowS: 5,
    starterLow: 0.2,
    starterNormal: 2.0,
    userCutoffMin: 1.0,
    userCutoffMax: 30,
    // Weekly calibration (D28): never below these, and only from a usual flow
    // (mean of the 5-minute averages) of at least calibrateMinMean.
    calibrateLowMin: 0.2,
    calibrateNormalMin: 1.0,
    calibrateMinMean: 1.25,
  },
  // Listings give F = 0.2 x Q and 10 to 200 L/min; confirm with the bucket test
  // (docs/hardware/NOTES.md). Below about 10 L/min the rotor may not turn, so
  // the No Flow line sits under it and calibration never sets limits lower.
  zj_dn50: {
    label: "ZJ-DN50",
    pulsesPerLpm: 0.2,
    flowWindowS: 15,
    starterLow: 5,
    starterNormal: 20,
    userCutoffMin: 10,
    userCutoffMax: 150,
    calibrateLowMin: 5,
    calibrateNormalMin: 10,
    calibrateMinMean: 12.5,
  },
} as const;
export type SensorType = keyof typeof SENSORS;
export const SENSOR_TYPES = Object.keys(SENSORS) as SensorType[];
export const DEFAULT_SENSOR: SensorType = "yf_s201";
// Kept for the YF-S201 paths and old callers.
export const STARTER_LOW_FLOW_CUTOFF = SENSORS.yf_s201.starterLow;
export const STARTER_NORMAL_FLOW_CUTOFF = SENSORS.yf_s201.starterNormal;
export const FLOW_RATE_MAX = 250;

// Alerts
// A flow problem alerts once it has lasted this long (checked at each
// upload, so about 30 to 40 s after the water stops).
export const ABNORMAL_CONFIRM_S = 30;
export const RECOVERY_CONFIRM_S = 600;
export const ALERT_LOCK_S = 21600;
export const ALERT_MAX_REMINDERS = 2;
export const ALERT_DAILY_CAP = 10;
export const SMS_PROJECT_DAILY_CAP = 100;
export const ALERT_SEND_LEASE_S = 120;
export const SMS_MAX_CHARS = 160;

// Write throttles and logs
export const DEVICES_WRITE_MIN_INTERVAL_S = 10;
export const DEVICES_WRITE_MAX_AGE_S = 300;
export const RATE_WRITE_DELTA_PCT = 15;
export const RATE_WRITE_MIN_ABS = 0.3;
// One flow sample per 15 min, for the weekly calibration only; the app
// reads problems, not flow_logs.
export const FLOW_LOG_SAMPLE_S = 900;
export const FLOW_LOG_TTL_DAYS = 7;
export const ERROR_LOG_DEDUPE_S = 3600;
export const ERROR_LOG_TTL_DAYS = 30;
export const ERROR_LOG_MESSAGE_MAX = 300;

// Outbound providers
export const SEMAPHORE_URL = "https://api.semaphore.co/api/v4/messages";
export const PROVIDER_TIMEOUT_MS = 10000;
/** Android notification channel with high importance, made by the app. */
export const ALERT_CHANNEL_ID = "alerts";
export const ALERT_EMAIL_FROM_NAME = "Hydro Sense";

// Calibration
export const CALIBRATE_SCHEDULE = "0 0 * * 0"; // weekly, Sunday 00:00 Asia/Manila
export const CALIBRATE_BUCKET_S = 300;
export const CALIBRATE_WINDOW_H = 24;
export const CALIBRATE_MIN_SAMPLES = 36;
export const CALIBRATE_SKIP_AFTER_ALERT_H = 24;
// The floors and the minimum mean are per sensor: SENSORS[...].calibrate*.
export const CALIBRATE_NORMAL_MAX_OF_MEAN = 0.8;
export const CALIBRATE_FALLBACK_NORMAL_OF_MEAN = 0.5;
export const CALIBRATE_FALLBACK_LOW_OF_MEAN = 0.15;

// Registration
export const REGISTER_MAX_PER_HOUR = 20;
export const NICKNAME_MAX = 24;
export const DEVICE_ID_PATTERN = /^[0-9A-F]{12}$/;

// Staff, admins and devices
export const USER_NAME_MAX = 60;
export const PH_MOBILE_PATTERN = /^(?:09|\+639|639)(\d{9})$/;
export const USERNAME_MIN = 3;
export const USERNAME_MAX = 20;
/** Staff sign in with a username; Firebase Auth needs an email, so the
 * account's sign-in address is username@STAFF_LOGIN_DOMAIN. Never sent mail. */
export const STAFF_LOGIN_DOMAIN = "staff.hydrosense.invalid";
// History
export const PROBLEM_TTL_DAYS = 365;
// The History graph: the 15-minute flow samples, one doc per device per
// Manila day (96 slots), kept a year. Asia/Manila has no daylight saving.
export const READINGS_TTL_DAYS = 365;
export const READING_SLOT_MIN = 15;
export const MANILA_UTC_OFFSET_MIN = 480;
export const PIPELINE_MAX_BRANCHES = 10;
export const PIPELINE_MAX_DEVICES_PER_BRANCH = 50;

// Passwords and admin setup
export const MIN_PASSWORD_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 128;
export const ADMIN_SETUP_MAX_PER_HOUR = 10;
export const ADMIN_SETUP_TOKEN_TTL_S = 3600;
export const ADMIN_RECOMMENDED_MIN = 2;
export const ADMIN_SITE_URL = "https://hydro-sense-dc836.web.app";

// Place search on the map: Google Places API (New), live suggestions.
// Places results may only be shown on a Google map, so the app's Map view uses
// Google road map tiles too. Free each month: 10,000 Autocomplete Requests and
// 10,000 Place Details Essentials (only `location` is asked for; the name comes
// from the suggestion, since displayName is the Pro SKU).
export const PLACES_AUTOCOMPLETE_URL = "https://places.googleapis.com/v1/places:autocomplete";
export const PLACES_DETAILS_URL = "https://places.googleapis.com/v1/places";
export const PLACES_REGION = "ph";
export const PLACES_LANGUAGE = "en";
export const PLACES_INPUT_MIN = 3;
export const PLACES_INPUT_MAX = 100;
export const PLACES_BIAS_RADIUS_M = 50000; // API maximum
// Calls (suggestions + picks) per day: one admin, and the whole project
// (300 a day stays under the 10,000 free a month).
export const PLACES_USER_DAILY_CAP = 150;
export const PLACES_PROJECT_DAILY_CAP = 300;
