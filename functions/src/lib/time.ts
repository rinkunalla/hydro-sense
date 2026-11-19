import { MANILA_UTC_OFFSET_MIN, READING_SLOT_MIN, TIME_ZONE } from "../config";

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

/** "Nov 2, 3:12 PM" in Asia/Manila. */
export const formatManila = (ms: number) => display.format(ms);

/** "2026-11-03" in Asia/Manila, the daily alert cap key. */
export const manilaDateKey = (ms: number) => dateKey.format(ms);

/** The minute of the Manila day (0 to 1439), for today's live series. */
export const manilaMinute = (ms: number) => {
  const local = ms + MANILA_UTC_OFFSET_MIN * 60_000;
  return Math.floor((((local % 86_400_000) + 86_400_000) % 86_400_000) / 60_000);
};

/** The 15-minute slot of the Manila day (0 to 95), for the History graph. */
export const manilaSlot = (ms: number) => {
  const local = ms + MANILA_UTC_OFFSET_MIN * 60_000;
  const minuteOfDay = Math.floor((((local % 86_400_000) + 86_400_000) % 86_400_000) / 60_000);
  return Math.floor(minuteOfDay / READING_SLOT_MIN);
};
