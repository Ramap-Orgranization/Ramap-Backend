import assert from "node:assert/strict";
import test from "node:test";
import { effectiveEndDate, isManageableEvent, validDate } from "../_shared/admin-event-policy.ts";

const today = "2026-10-11";
const event = (start, end = null, type = "limited_menu") => ({ start_date: start, end_date: end, event_type: type });
test("expired dated events and old renewal news stay out of management", () => {
  assert.equal(isManageableEvent(event("2026-10-01", "2026-10-10"), today), false);
  assert.equal(isManageableEvent(event("2026-08-01", null, "store_renewal"), today), false);
});
test("today and upcoming events remain editable", () => {
  assert.equal(isManageableEvent(event(today), today), true);
  assert.equal(isManageableEvent(event("2026-10-12"), today), true);
  assert.equal(isManageableEvent(event("2026-10-01", today), today), true);
});
test("renewals retain their one-month news window", () => {
  assert.equal(effectiveEndDate(event("2026-10-01", "2026-10-30", "store_renewal")), "2026-10-31");
});
test("date validation rejects impossible dates and permits leap days", () => {
  assert.equal(validDate("2026-02-29"), false);
  assert.equal(validDate("2028-02-29"), true);
  assert.equal(validDate("2026-13-01"), false);
  assert.equal(validDate(null), false);
});

test("open-ended menus remain visible and legacy new menus expire after seven days", () => {
  assert.equal(isManageableEvent(event("2026-01-01"), today), true);
  assert.equal(isManageableEvent(event("2026-10-01", null, "new_menu"), today), false);
  assert.equal(isManageableEvent(event("2026-10-05", null, "new_menu"), today), true);
});
test("renewal month arithmetic matches Postgres at month boundaries", () => {
  assert.equal(effectiveEndDate(event("2026-01-31", null, "store_renewal")), "2026-02-27");
  assert.equal(effectiveEndDate(event("2028-01-31", null, "store_renewal")), "2028-02-28");
});
