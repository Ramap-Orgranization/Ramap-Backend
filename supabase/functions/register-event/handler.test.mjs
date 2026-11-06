import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import test from "node:test";
import { validCalendarDate, validClosureSchedules } from "../_shared/operating-notice-schedule.ts";

const source = stripTypeScriptTypes((await readFile(new URL("./index.ts", import.meta.url), "utf8")).replace(/^import .*;\n/gm, ""));
const schedule = { closed: false, open: "11:00", close: "20:00", close_next_day: false, label: null, break_times: [] };
const base = { shop_name: "테스트 매장", title: "연속 일정", description: "테스트 일정", source_url: "https://www.instagram.com/test_shop/", start_date: "2026-10-30", end_date: "2026-11-02" };

function harness({ allowed = true, overlapping = false } = {}) {
  let handler;
  const calls = { inserts: [], filters: [], clients: 0 };
  function from(table) {
    const filters = [];
    let inserted = false;
    const query = {
      select() { return this; },
      eq(key, value) { filters.push(["eq", key, value]); return this; },
      in(key, value) { filters.push(["in", key, value]); return this; },
      lte(key, value) { filters.push(["lte", key, value]); return this; },
      or(value) { filters.push(["or", value]); return this; },
      not(...args) { filters.push(["not", ...args]); return this; },
      is() { return this; },
      delete() { return this; },
      insert(value) { inserted = true; calls.inserts.push({ table, value }); return this; },
      limit() { return this; },
      async maybeSingle() { return { data: { id: "raw-post" }, error: null }; },
      async single() { return { data: { id: "notice" }, error: null }; },
      then(resolve, reject) {
        calls.filters.push({ table, filters });
        const data = table === "ramen_shops" ? [{ id: "shop" }] : inserted ? [{ id: "notice" }] :
          !inserted && table === "admin_shop_operating_notice_records" && overlapping && filters.some(([op]) => op === "not") ? [{ id: "overlap" }] : [];
        return Promise.resolve({ data, error: null }).then(resolve, reject);
      },
    };
    return query;
  }
  runInNewContext(source, {
    Deno: { serve: (value) => { handler = value; } },
    Request, Response, URL, Date, crypto, console,
    validCalendarDate, validClosureSchedules,
    mediaStorage: (client) => client.storage,
    isAdministrator: async () => allowed,
    createServiceClient: () => { calls.clients++; return { from }; },
    assertKnownEventType: (value) => { assert.ok(["collab", "popup", "limited_menu", "summer_limited", "new_menu", "store_renewal"].includes(value)); },
    normalizeMapUrl: () => null,
    requiresExistingVenueSelection: () => false,
  });
  return {
    calls,
    invoke: (body) => handler(new Request("https://example.com/register-event", { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json" } })),
  };
}

test("only administrators can register date ranges", async () => {
  const app = harness({ allowed: false });
  assert.equal((await app.invoke(base)).status, 403);
  assert.equal(app.calls.clients, 0);
});

for (const type of ["limited_menu", "popup"]) {
  test(`${type} retains both dates across a month boundary`, async () => {
    const app = harness();
    assert.equal((await app.invoke({ ...base, registration_type: "event", event_type: type })).status, 200);
    const row = app.calls.inserts.find(({ table }) => table === "shop_events").value;
    assert.equal(row.start_date, base.start_date);
    assert.equal(row.end_date, base.end_date);
  });
}

for (const type of ["full_close", "early_close", "planned_close"]) {
  test(`${type} 공지는 관리자 경로에 연속 기간과 검토 메모를 저장한다`, async () => {
    const app = harness();
    const body = { ...base, registration_type: "operating_notice", notice_type: type, end_time: type !== "full_close" ? "15:00" : null };
    const response = await app.invoke(body);
    assert.equal(response.status, 200, JSON.stringify(await response.json()));
    const row = app.calls.inserts.find(({ table }) => table === "admin_shop_operating_notice_records").value[0];
    assert.equal(row.notice_date, base.start_date);
    assert.equal(row.end_date, base.end_date);
    assert.equal(row.review_note, "관리자 미리보기 승인 등록");
  });
}

test("제거한 공지 유형과 마감 시각 없는 조기 마감은 쓰기 전에 거절한다", async () => {
  for (const notice_type of ["operating_notice", "late_opening", "early_close", "planned_close"]) {
    const app = harness();
    assert.equal((await app.invoke({ ...base, registration_type: "operating_notice", notice_type })).status, 400);
    assert.equal(app.calls.inserts.length, 0);
  }
});

test("임시 휴무에는 시간이나 변경 영업시간을 저장하지 않는다", async () => {
  for (const fields of [{ start_time: "12:00" }, { end_time: "15:00" }, { schedule_override: schedule }]) {
    const app = harness();
    assert.equal((await app.invoke({ ...base, registration_type: "operating_notice", notice_type: "full_close", ...fields })).status, 400);
    assert.equal(app.calls.inserts.length, 0);
  }
});

test("reversed and impossible ranges are rejected before any write", async () => {
  for (const registration_type of ["event", "operating_notice"]) {
    for (const dates of [{ start_date: "2026-11-02", end_date: "2026-10-30" }, { start_date: "2026-02-30", end_date: "2026-03-01" }]) {
      const app = harness();
      const response = await app.invoke({ ...base, ...dates, registration_type, notice_type: "operating_notice", schedule_override: schedule });
      assert.equal(response.status, 400);
      assert.equal(app.calls.inserts.length, 0);
    }
  }
});

test("월간 휴무는 명시된 휴무일만 개별 공지로 한 번에 저장한다", async () => {
  const app = harness();
  const daily_schedules = [
    { date: "2026-10-06", closed: true, schedule_override: null },
    { date: "2026-10-08", closed: false, schedule_override: null },
    { date: "2026-10-13", closed: true, schedule_override: null },
  ];
  const response = await app.invoke({ ...base, registration_type: "operating_notice", notice_type: "full_close", start_date: "2026-10-01", end_date: "2026-10-31", daily_schedules });
  assert.equal(response.status, 200);
  const rows = app.calls.inserts[0].value;
  assert.equal(JSON.stringify(rows.map((row) => [row.notice_date, row.end_date, row.daily_schedules])), JSON.stringify([["2026-10-06", "2026-10-06", []], ["2026-10-13", "2026-10-13", []]]));
});

test("잘못된 달력 항목은 예외 없이 쓰기 전에 거절한다", async () => {
  for (const daily_schedules of [[null], [{ date: "2026-10-14", closed: false, schedule_override: null }]]) {
    const app = harness();
    assert.equal((await app.invoke({ ...base, registration_type: "operating_notice", notice_type: "full_close", start_date: "2026-10-01", end_date: "2026-10-31", daily_schedules })).status, 400);
    assert.equal(app.calls.inserts.length, 0);
  }
});
