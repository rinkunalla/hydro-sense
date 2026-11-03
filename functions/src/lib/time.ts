import { TIME_ZONE } from "../config";

const display = new Intl.DateTimeFormat("en-US", {
  timeZone: TIME_ZONE,
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
});

const dateKey = new Intl.DateTimeFormat("en-CA", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** "Nov 2, 3:12 PM" in Asia/Manila (docs/UI_UX_SPEC.md section 6). */
export const formatManila = (ms: number) => display.format(ms);

/** "2026-11-03" in Asia/Manila, the daily alert cap key. */
export const manilaDateKey = (ms: number) => dateKey.format(ms);
