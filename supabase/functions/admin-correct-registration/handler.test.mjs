import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import test from "node:test";
import { effectiveEndDate, isManageableEvent } from "../_shared/admin-event-policy.ts";

const source = stripTypeScriptTypes((await readFile(new URL("./index.ts", import.meta.url), "utf8")).replace(/^import .*;\n/gm, ""));
function harness(record = { event_type: "limited_menu", start_date: "2026-01-01", end_date: null }) {
  const updates = [];
  const tables = [];
  const query = {
    select() { return this; }, eq() { return this; },
    async maybeSingle() { return { data: record, error: null }; },
    update(value) { updates.push(value); return { eq: async () => ({ error: null }) }; },
  };
  const context = { Deno: { serve() {} }, Response, Date, Intl, effectiveEndDate, isManageableEvent, createServiceClient: () => ({ from: (table) => { tables.push(table); return query; } }) };
  runInNewContext(source + "\nglobalThis.api = { validateChanges, applyCorrection, isActiveRecord, matchesNoticeDate };", context);
  return { ...context.api, updates, tables };
}
test("event title and type corrections are retained instead of dropped by the notice branch", () => {
  const api = harness();
  assert.equal(api.validateChanges("event", { title: "Changed" }).title, "Changed");
  assert.equal(api.validateChanges("event", { event_type: "popup" }).event_type, "popup");
  assert.equal(api.validateChanges("operating_notice", { title: "Not supported" }), null);
});
test("title-only correction updates the event", async () => {
  const api = harness();
  const response = await api.applyCorrection("event", "event", { title: "Changed" });
  assert.equal(response.status, 200);
  assert.equal(api.updates[0].title, "Changed");
});
test("제거된 영업시간 변경 보정은 거절한다", async () => {
  const api = harness({ notice_type: "operating_notice", notice_date: "2099-01-01", end_date: null });
  const response = await api.applyCorrection("operating_notice", "notice", { schedule_override: { open: "11:00", close: "21:00" } });
  assert.equal(response.status, 400);
  assert.equal(api.updates.length, 0);
});
test("schedule override cannot be applied to a closure", async () => {
  const api = harness({ notice_type: "full_close", notice_date: "2099-01-01", end_date: null });
  assert.equal((await api.applyCorrection("operating_notice", "notice", { schedule_override: { open: "11:00" } })).status, 400);
  assert.equal(api.updates.length, 0);
});
test("영업 공지 보정은 공개 조회 경로 대신 서비스 전용 경로에 저장한다", async () => {
  const api = harness({ notice_type: "full_close", notice_date: "2099-01-01", end_date: null });
  const response = await api.applyCorrection("operating_notice", "notice", { description: "변경 공지" });
  assert.equal(response.status, 200);
  assert.equal(api.tables.at(-1), "admin_shop_operating_notice_records");
  assert.equal(api.updates[0].description, "변경 공지");
});
test("expired renewal and new-menu records cannot be corrected", () => {
  const api = harness();
  assert.equal(api.isActiveRecord("event", { event_type: "store_renewal", start_date: "2020-01-01", end_date: null }), false);
  assert.equal(api.isActiveRecord("event", { event_type: "new_menu", start_date: "2020-01-01", end_date: null }), false);
});

test("조기 마감으로 변경할 때 확인된 마감 시각이 필요하다", async () => {
  const api = harness({ notice_type: "full_close", notice_date: "2099-01-01", end_date: null });
  assert.equal((await api.applyCorrection("operating_notice", "notice", { notice_type: "early_close" })).status, 400);
  assert.equal((await api.applyCorrection("operating_notice", "notice", { notice_type: "early_close", end_time: "15:00" })).status, 200);
  assert.equal(api.updates[0].end_time, "15:00");
});
test("임시 휴무로 변경하면 이전 조기 마감 시각을 비운다", async () => {
  const api = harness({ notice_type: "early_close", notice_date: "2099-01-01", end_date: null, end_time: "15:00:00" });
  assert.equal((await api.applyCorrection("operating_notice", "notice", { notice_type: "full_close" })).status, 200);
  assert.equal(api.updates[0].end_time, null);
});

test("같은 달력에서 분리한 휴무 공지는 요청한 대상 날짜로 구분한다", () => {
  const api = harness();
  assert.equal(api.matchesNoticeDate({ notice_date: "2099-10-21", end_date: "2099-10-21" }, "2099-10-21"), true);
  assert.equal(api.matchesNoticeDate({ notice_date: "2099-10-28", end_date: "2099-10-28" }, "2099-10-21"), false);
});

for (const notice_type of ["early_close", "planned_close"]) {
  test(`${notice_type} 보정은 정확한 종료 시각이 있어야 하고 두 유형 간 전환에서 시각을 유지한다`, async () => {
    const empty = harness({ notice_type: "full_close", notice_date: "2099-01-01", end_date: null });
    assert.equal((await empty.applyCorrection("operating_notice", "notice", { notice_type })).status, 400);
    const api = harness({ notice_type: "early_close", notice_date: "2099-01-01", end_date: null, end_time: "15:00:00" });
    assert.equal((await api.applyCorrection("operating_notice", "notice", { notice_type })).status, 200);
    assert.equal(api.updates[0].notice_type, notice_type);
    assert.equal(api.updates[0].end_time, undefined); // Omitted field preserves the stored closing time.
  });
}
