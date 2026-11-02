import {
  BATTERY_CELL_EMPTY_V,
  BATTERY_CELL_SPAN_V,
  BATTERY_SERIES_CELLS,
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

const mean = (xs: readonly number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

/** Newest vs oldest CHARGING_TREND_SAMPLES means of recentVoltages (CLAUDE.md section 6). */
export function chargingTrend(
  recent: readonly number[],
  cells = BATTERY_SERIES_CELLS,
): ChargingStatus {
  const n = Math.min(CHARGING_TREND_SAMPLES, Math.floor(recent.length / 2));
  if (n < 1) return "Steady";
  const older = mean(recent.slice(0, n));
  const newer = mean(recent.slice(-n));
  const threshold = CHARGING_RISE_PER_CELL_V * cells;
  // Compare with a small tolerance so float noise at the threshold counts as reaching it.
  const delta = newer - older;
  const eps = 1e-9;
  if (delta >= threshold - eps) return "Charging";
  if (delta <= -threshold + eps) return "Discharging";
  if (newer >= CHARGING_FULL_PER_CELL_V * cells) return "Full";
  return "Steady";
}
