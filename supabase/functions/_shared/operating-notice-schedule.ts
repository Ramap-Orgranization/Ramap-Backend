export type DailySchedule = {
  date: string;
  closed: boolean;
  schedule_override: {
    closed: boolean;
    open: string | null;
    close: string | null;
    close_next_day: boolean;
    label: string | null;
    break_times: Array<{ start: string; end: string }>;
  } | null;
};

export function validCalendarDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function validTime(value: unknown): value is string {
  return typeof value === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(value);
}

export function validDailySchedules(value: unknown, start: string, end: string): value is DailySchedule[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 31) return false;
  if (!validCalendarDate(start) || !validCalendarDate(end) || start > end || start.slice(0, 7) !== end.slice(0, 7)) return false;
  const dates = new Set<string>();
  for (const day of value) {
    if (!day || typeof day !== "object" || !validCalendarDate(day.date) || typeof day.closed !== "boolean") return false;
    if (day.date < start || day.date > end || dates.has(day.date)) return false;
    dates.add(day.date);
    const override = day.schedule_override;
    if (override == null) continue;
    if (day.closed || override.closed !== false || !validTime(override.open) || !validTime(override.close)) return false;
    if (typeof override.close_next_day !== "boolean" || (override.label !== null && typeof override.label !== "string")) return false;
    if (override.close_next_day ? override.close > override.open : override.close <= override.open) return false;
    if (!Array.isArray(override.break_times) || override.break_times.some((period: { start: unknown; end: unknown } | null) => !period || !validTime(period.start) || !validTime(period.end))) return false;
  }
  return true;
}

export const dailySchedulesSchema = {
  type: "array",
  items: {
    type: "object", additionalProperties: false,
    properties: {
      date: { type: "string" }, closed: { type: "boolean" },
      schedule_override: {
        type: ["object", "null"], additionalProperties: false,
        properties: {
          closed: { type: "boolean" }, open: { type: ["string", "null"] }, close: { type: ["string", "null"] },
          close_next_day: { type: "boolean" }, label: { type: ["string", "null"] },
          break_times: { type: "array", items: { type: "object", additionalProperties: false, properties: { start: { type: "string" }, end: { type: "string" } }, required: ["start", "end"] } },
        },
        required: ["closed", "open", "close", "close_next_day", "label", "break_times"],
      },
    },
    required: ["date", "closed", "schedule_override"],
  },
};

export function validClosureSchedules(value: unknown, start: string, end: string): value is DailySchedule[] {
  return validDailySchedules(value, start, end) && value.some((day) => day.closed) && value.every((day) => day.schedule_override == null);
}
