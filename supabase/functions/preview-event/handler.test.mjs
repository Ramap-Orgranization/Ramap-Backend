import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import test from "node:test";
import { dailySchedulesSchema, validCalendarDate, validClosureSchedules } from "../_shared/operating-notice-schedule.ts";

const source = stripTypeScriptTypes((await readFile(new URL("./index.ts", import.meta.url), "utf8")).replace(/^import .*;\n/gm, ""));
function harness(draft) {
  let handler;
  const query = {
    select() { return this; }, eq() { return this; },
    async limit() { return { data: [{ name: "테스트 매장", instagram_url: "https://www.instagram.com/test_shop/" }] }; },
  };
  runInNewContext(source, {
    Deno: { serve(value) { handler = value; }, env: { get() { return "synthetic"; } } },
    Request, Response, URL, Date, console,
    dailySchedulesSchema, validCalendarDate, validClosureSchedules,
    mediaStorage: (client) => client.storage,
    isAdministrator: async () => true,
    createServiceClient: () => ({ from: () => query, storage: { from: () => ({ createSignedUrl: async () => ({ data: { signedUrl: "https://example.invalid/evidence.png" }, error: null }) }) } }),
    normalizeMapUrl: () => null,
    fetch: async () => Response.json({ choices: [{ message: { content: JSON.stringify({ description: "점심만 영업", start_date: "2099-10-14", end_date: "2099-10-14", daily_schedules: [], uncertainties: [], ...draft }) } }] }),
  });
  return async () => {
    const response = await handler(new Request("https://example.invalid/preview", { method: "POST", body: JSON.stringify({ registration_type: "operating_notice", shop_name: "테스트 매장", evidence_path: "proof.png" }) }));
    assert.equal(response.status, 200);
    return response.json();
  };
}

test("점심만 영업의 마감 시각이 없으면 확인이 필요한 운영 변동 초안으로 남긴다", async () => {
  const draft = await harness({ notice_type: "planned_close", end_time: null })();
  assert.equal(draft.notice_type, "planned_close");
  assert.equal(draft.end_time, null);
  assert.ok(draft.uncertainties.some((item) => item.includes("마감 시각")));
});

test("제거한 공지 유형은 미리보기에서 등록 가능한 유형으로 통과시키지 않는다", async () => {
  for (const notice_type of ["operating_notice", "late_opening"]) {
    const draft = await harness({ notice_type, start_time: "12:00", schedule_override: { open: "12:00", close: "18:00" } })();
    assert.equal(draft.notice_type, null);
    assert.equal(draft.start_time, null);
    assert.equal(draft.schedule_override, null);
  }
});

test("하루 휴무를 월간 일정으로 분석해도 실제 하루 공지로 미리보기를 반환한다", async () => {
  const draft = await harness({
    notice_type: "full_close", start_date: "2026-10-01", end_date: "2026-10-31",
    daily_schedules: [{ date: "2026-10-15", closed: true, schedule_override: null }],
  })();
  assert.equal(draft.start_date, "2026-10-15");
  assert.equal(draft.end_date, "2026-10-15");
  assert.deepEqual(draft.daily_schedules, []);
  assert.equal(draft.notice_type, "full_close");
});

test("분석이 기간을 누락해도 여러 날짜 공지는 확인된 날짜 범위와 휴무만 보존한다", async () => {
  const days = [
    { date: "2026-10-20", closed: true, schedule_override: null },
    { date: "2026-10-15", closed: true, schedule_override: null },
    { date: "2026-10-17", closed: false, schedule_override: null },
  ];
  const draft = await harness({ notice_type: "full_close", start_date: null, end_date: null, daily_schedules: days })();
  assert.equal(draft.start_date, "2026-10-15");
  assert.equal(draft.end_date, "2026-10-20");
  assert.deepEqual(draft.daily_schedules, days);
});

test("잘못된 일정은 전체 미리보기를 실패시키거나 연속 휴무로 바꾸지 않는다", async () => {
  for (const days of [
    [{ date: "2026-02-30", closed: true, schedule_override: null }],
    [{ date: "2026-10-15", closed: false, schedule_override: null }],
    [{ date: "2026-10-15", closed: true, schedule_override: {} }],
    [{ date: "2026-10-15", closed: true, schedule_override: null }, { date: "2026-10-15", closed: true, schedule_override: null }],
    [null],
  ]) {
    const draft = await harness({ notice_type: "full_close", start_date: "2026-10-01", end_date: "2026-10-31", daily_schedules: days })();
    assert.equal(draft.notice_type, null);
    assert.equal(draft.start_date, null);
    assert.equal(draft.end_date, null);
    assert.deepEqual(draft.daily_schedules, []);
    assert.ok(draft.uncertainties.length > 0);
    assert.equal(draft.description, "점심만 영업");
  }
});

for (const notice_type of ["early_close", "planned_close"]) {
  test(`${notice_type}는 확인된 종료 시각을 유지한다`, async () => {
    const draft = await harness({ notice_type, end_time: "16:00" })();
    assert.equal(draft.notice_type, notice_type);
    assert.equal(draft.end_time, "16:00");
  });
}
