// Every backend tunable lives here (CLAUDE.md working rule 5). Values come from
// CLAUDE.md sections 4 to 8 and docs/ERROR_HANDLING.md section 6.

// Deployment
export const REGION = "asia-east1";
export const MAX_INSTANCES = 2;
export const TIME_ZONE = "Asia/Manila";

// Device health and offline detection
// Upload pace the server hands to firmware 0.3.0+ in every reply, so it can be
// tuned without a reflash. Firmware clamps both to its own safe range.
export const DEVICE_HEARTBEAT_S = 30;
export const DEVICE_RATE_MIN_INTERVAL_S = 10;
/** A device that reports its heartbeat goes offline after this many missed. */
export const OFFLINE_MISSED_HEARTBEATS = 3;
export const OFFLINE_AFTER_MIN_S = 60;
/** For firmware that does not report its heartbeat (0.2.0, 60 s heartbeats). */
export const OFFLINE_AFTER_S = 180;
export const HEARTBEAT_REPORTED_MIN_S = 10;
export const HEARTBEAT_REPORTED_MAX_S = 120;
export const OFFLINE_ALERT_AFTER_S = 900;
export const RECENT_VOLTAGES_CAP = 20;
export const BATTERY_SERIES_CELLS = 2;
export const BATTERY_CELL_EMPTY_V = 3.3;
export const BATTERY_CELL_SPAN_V = 0.9;
export const LOW_BATTERY_PERCENT = 20;
export const BATTERY_REARM_PERCENT = 30;
export const CHARGING_TREND_SAMPLES = 5;
/** batteryPercent is shown from the mean of the newest readings, so ADC noise
 * of a few mV (1 % is 18 mV on 2S) does not make it jump 81 → 83 → 82. */
export const BATTERY_SMOOTH_SAMPLES = 5;
export const CHARGING_RISE_PER_CELL_V = 0.02;
export const CHARGING_FULL_PER_CELL_V = 4.15;

// Flow classification (starter cutoffs, L/min) and payload clamps
export const STARTER_LOW_FLOW_CUTOFF = 0.2;
export const STARTER_NORMAL_FLOW_CUTOFF = 2.0;
// Owner's own "Low flow below X L/min" (D43). The YF-S201 reads about 1 to 30
// L/min reliably (D7), so X stays inside that range. Mirrored in firestore.rules.
export const USER_NORMAL_CUTOFF_MIN = 1.0;
export const USER_NORMAL_CUTOFF_MAX = 30;
export const FLOW_RATE_MAX = 40;

// Alerts
export const ABNORMAL_CONFIRM_S = 60;
export const RECOVERY_CONFIRM_S = 600;
export const ALERT_LOCK_S = 21600;
export const ALERT_MAX_REMINDERS = 2;
export const ALERT_DAILY_CAP = 10;
export const SMS_PROJECT_DAILY_CAP = 50;
export const ALERT_SEND_LEASE_S = 120;
export const SMS_MAX_CHARS = 160;

// Write throttles and logs
export const DEVICES_WRITE_MIN_INTERVAL_S = 10;
export const DEVICES_WRITE_MAX_AGE_S = 300;
export const RATE_WRITE_DELTA_PCT = 15;
export const RATE_WRITE_MIN_ABS = 0.3;
export const FLOW_LOG_SAMPLE_S = 300;
export const FLOW_LOG_TTL_DAYS = 7;
export const ERROR_LOG_DEDUPE_S = 3600;
export const ERROR_LOG_TTL_DAYS = 30;
export const ERROR_LOG_MESSAGE_MAX = 300;

// Outbound providers
export const SEMAPHORE_URL = "https://api.semaphore.co/api/v4/messages";
export const SEMAPHORE_OTP_URL = "https://api.semaphore.co/api/v4/otp"; // 2 credits per SMS
export const PROVIDER_TIMEOUT_MS = 10000;
export const ALERT_EMAIL_FROM_NAME = "Hydro Sense";

// Calibration
export const CALIBRATE_SCHEDULE = "0 0 * * 0"; // weekly, Sunday 00:00 Asia/Manila
export const CALIBRATE_BUCKET_S = 300;
export const CALIBRATE_WINDOW_H = 24;
export const CALIBRATE_MIN_SAMPLES = 36;
export const CALIBRATE_MIN_MEAN = 1.25;
export const CALIBRATE_SKIP_AFTER_ALERT_H = 24;
export const CALIBRATE_LOW_MIN = 0.2;
export const CALIBRATE_NORMAL_MIN = 1.0;
export const CALIBRATE_NORMAL_MAX_OF_MEAN = 0.8;
export const CALIBRATE_FALLBACK_NORMAL_OF_MEAN = 0.5;
export const CALIBRATE_FALLBACK_LOW_OF_MEAN = 0.15;

// Registration
export const REGISTER_MAX_PER_HOUR = 20;
export const NICKNAME_MAX = 24;
export const DEVICE_ID_PATTERN = /^[0-9A-F]{12}$/;

// Users, devices and admin actions (CLAUDE.md sections 4 and 6, D20, D32, D42)
export const USER_NAME_MAX = 60;
export const LABEL_MAX = 24;
export const PH_MOBILE_PATTERN = /^(?:09|\+639|639)(\d{9})$/;
export const RESTORE_WINDOW_DAYS = 30;
export const AUDIT_TTL_DAYS = 365;
export const AUDIT_LIST_LIMIT = 50;
export const PIPELINE_MAX_BRANCHES = 10;
export const PIPELINE_MAX_DEVICES_PER_BRANCH = 50;

// Sign-in codes and admin setup (CLAUDE.md sections 6 and 8, D22, D23, D30, D31)
export const RESET_CODE_LENGTH = 6;
export const RESET_CODE_TTL_S = 300;
export const RESET_MAX_ATTEMPTS = 5;
export const RESET_RESEND_S = 60;
export const RESET_MAX_PER_PHONE_DAY = 5;
export const RESET_TOKEN_TTL_S = 600;
export const OTP_PROJECT_DAILY_CAP = 30;
export const MIN_PASSWORD_LENGTH = 8;
export const ADMIN_SETUP_MAX_PER_HOUR = 10;
export const ADMIN_SETUP_TOKEN_TTL_S = 3600;
export const ADMIN_RECOMMENDED_MIN = 2;
export const ADMIN_SITE_URL = "https://hydro-sense-dc836.web.app";

// Place search on the map: Google Places API (New), live suggestions (D46).
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
// Calls (suggestions + picks) per day: one user, and the whole project
// (300 a day stays under the 10,000 free a month).
export const PLACES_USER_DAILY_CAP = 150;
export const PLACES_PROJECT_DAILY_CAP = 300;
