type ManagedEvent = { event_type: string; start_date: string; end_date: string | null };

// Match the renewal news window and the seven-day new-menu registration rule.
// Other events can intentionally have no known end date.
export function effectiveEndDate(event: ManagedEvent): string | null {
  const start = new Date(`${event.start_date}T00:00:00Z`);
  if (event.event_type === "store_renewal") {
    const lastDay = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 2, 0)).getUTCDate();
    const end = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, Math.min(start.getUTCDate(), lastDay)));
    end.setUTCDate(end.getUTCDate() - 1);
    return end.toISOString().slice(0, 10);
  }
  if (event.event_type === "new_menu") {
    start.setUTCDate(start.getUTCDate() + 6);
    return start.toISOString().slice(0, 10);
  }
  return event.end_date;
}

export function isManageableEvent(event: ManagedEvent, today: string): boolean {
  const end = effectiveEndDate(event);
  return end === null || end >= today;
}

export function validDate(value: string | null): value is string {
  if (value === null || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().startsWith(value);
}
