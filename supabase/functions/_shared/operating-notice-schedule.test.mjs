import assert from 'node:assert/strict';
import test from 'node:test';
import { validDailySchedules, validCalendarDate } from './operating-notice-schedule.ts';
const closed = { date: '2026-10-06', closed: true, schedule_override: null };
const regular = { date: '2026-10-08', closed: false, schedule_override: null };
const validate = (days) => validDailySchedules(days, '2026-10-01', '2026-10-31');
test('accepts separated closures and explicit regular days in one notice', () => {
  assert.equal(validate([closed, regular, { ...closed, date: '2026-10-13' }]), true);
});
test('rejects invalid dates, duplicates, out of month and malformed flags', () => {
  assert.equal(validCalendarDate('2026-02-30'), false);
  for (const days of [[], null, {}, [closed, closed], [{ ...closed, date: '2026-11-01' }], [{ ...closed, closed: 'true' }]]) assert.equal(validate(days), false);
});
test('requires explicit valid hours for overrides and never guesses regular hours', () => {
  const override = { closed: false, open: '11:00', close: '22:00', close_next_day: false, label: null, break_times: [] };
  assert.equal(validate([{ ...regular, schedule_override: override }]), true);
  assert.equal(validate([{ ...closed, schedule_override: override }]), false);
  assert.equal(validate([{ ...regular, schedule_override: { ...override, open: '25:00' } }]), false);
  assert.equal(validate([{ ...regular, schedule_override: { ...override, close: '10:00' } }]), false);
  assert.equal(validate([{ ...regular, schedule_override: { ...override, close: '02:00', close_next_day: true } }]), true);
});
