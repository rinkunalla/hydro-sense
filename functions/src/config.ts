// Every backend tunable lives here (CLAUDE.md working rule 5). Values come from
// CLAUDE.md sections 4 to 8 and docs/ERROR_HANDLING.md section 6.

// Deployment
export const REGION = "asia-east1";
export const MAX_INSTANCES = 2;
export const TIME_ZONE = "Asia/Manila";

// Device health and offline detection
export const OFFLINE_AFTER_S = 180;
export const OFFLINE_ALERT_AFTER_S = 900;
export const RECENT_VOLTAGES_CAP = 20;
export const BATTERY_SERIES_CELLS = 2;
export const BATTERY_CELL_EMPTY_V = 3.3;
export const BATTERY_CELL_SPAN_V = 0.9;
export const LOW_BATTERY_PERCENT = 20;
export const BATTERY_REARM_PERCENT = 30;
export const CHARGING_TREND_SAMPLES = 5;
export const CHARGING_RISE_PER_CELL_V = 0.02;
export const CHARGING_FULL_PER_CELL_V = 4.15;

// Flow classification (starter cutoffs, L/min) and payload clamps
export const STARTER_LOW_FLOW_CUTOFF = 0.2;
export const STARTER_NORMAL_FLOW_CUTOFF = 2.0;
export const FLOW_RATE_MAX = 40;
export const PULSES_PER_LPM = 7.5;

// Alerts
export const ABNORMAL_CONFIRM_S = 60;
export const RECOVERY_CONFIRM_S = 600;
export const ALERT_LOCK_S = 21600;
export const ALERT_MAX_REMINDERS = 2;
export const ALERT_DAILY_CAP = 10;
export const ALERT_SEND_LEASE_S = 120;
export const SMS_MAX_CHARS = 160;
export const PAUSE_MAX_DAYS = 7;

// Write throttles and logs
export const DEVICES_WRITE_MIN_INTERVAL_S = 30;
export const DEVICES_WRITE_MAX_AGE_S = 300;
export const RATE_WRITE_DELTA_PCT = 15;
export const RATE_WRITE_MIN_ABS = 0.3;
export const FLOW_LOG_SAMPLE_S = 300;
export const FLOW_LOG_TTL_DAYS = 7;
export const BATTERY_LOG_S = 900;
export const BATTERY_LOG_TTL_DAYS = 14;
export const ERROR_LOG_DEDUPE_S = 3600;
export const ERROR_LOG_TTL_DAYS = 30;
export const ERROR_LOG_MESSAGE_MAX = 300;

// AI
export const AI_COOLDOWN_S = 900;
export const AI_TIMEOUT_MS = 15000;
export const AI_MAX_OUTPUT_TOKENS = 256;

// Calibration
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

// Callable cooldowns
export const CLIENT_CALIBRATE_COOLDOWN_S = 3600;
export const ADMIN_REPORT_COOLDOWN_S = 3600;

// Registration
export const REGISTER_MAX_PER_HOUR = 20;
export const NICKNAME_MAX = 24;
export const DEVICE_ID_PATTERN = /^[0-9A-F]{12}$/;
