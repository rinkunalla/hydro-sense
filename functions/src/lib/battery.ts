import {
  BATTERY_CELL_EMPTY_V,
  BATTERY_CELL_SPAN_V,
  BATTERY_SERIES_CELLS,
  BATTERY_SMOOTH_SAMPLES,
  CHARGING_FULL_PER_CELL_V,
  CHARGING_RISE_PER_CELL_V,
  CHARGING_TREND_SAMPLES,
  RECENT_VOLTAGES_CAP,
} from "../config";

export type ChargingStatus = "Charging" | "Full" | "Discharging" | "Steady";

/** Percent = (Vpack − 3.3·N) / (0.9·N), clamped 0 to 100 (CLAUDE.md D2). */
export function batteryPercent(packVoltage: number, cells = BATTERY_SERIES_CELLS): number {
  const pct =
    ((packVoltage - BATTERY_CELL_EMPTY_V * cells) / (BATTERY_CELL_SPAN_V * cells)) * 100;
  return Math.round(Math.min(100, Math.max(0, pct)));
}

export function appendVoltage(list: readonly number[], v: number, cap = RECENT_VOLTAGES_CAP) {
  return [...list, v].slice(-cap);
}

/** The middle value: one dipped or spiked reading cannot move it (D56). */
export function median(xs: readonly number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}

/** Median of the newest [samples] readings, for a steady batteryPercent. */
export function smoothedVoltage(
  recent: readonly number[],
  samples = BATTERY_SMOOTH_SAMPLES,
): number {
  return median(recent.slice(-samples));
}

/**
 * Newest vs oldest CHARGING_TREND_SAMPLES medians of recentVoltages (about
 * 7.5 min each, up to 30 min apart). Medians, so a single dip leaving the
 * window no longer looks like the voltage rising (D56).
 */
export function chargingTrend(
  recent: readonly number[],
  cells = BATTERY_SERIES_CELLS,
): ChargingStatus {
  const n = Math.min(CHARGING_TREND_SAMPLES, Math.floor(recent.length / 2));
  if (n < 1) return "Steady";
  const older = median(recent.slice(0, n));
  const newer = median(recent.slice(-n));
  const threshold = CHARGING_RISE_PER_CELL_V * cells;
  // Compare with a small tolerance so float noise at the threshold counts as reaching it.
  const delta = newer - older;
  const eps = 1e-9;
  if (delta >= threshold - eps) return "Charging";
  if (delta <= -threshold + eps) return "Discharging";
  if (newer >= CHARGING_FULL_PER_CELL_V * cells) return "Full";
  return "Steady";
}
