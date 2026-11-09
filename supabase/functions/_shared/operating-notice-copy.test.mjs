import assert from "node:assert/strict";
import test from "node:test";
import { automaticOperatingNoticeCopy } from "./operating-notice-copy.ts";
import { buildPublicationPayload, validateFact } from "./notification-payload.ts";
import { previewPublication } from "./notification-publication.ts";
import { fact, id, source } from "./notification-fixtures.mjs";
const year = new Intl.DateTimeFormat("en", { year: "numeric", timeZone: "Asia/Seoul" }).format(new Date());
const automatic = (overrides = {}) => fact({ id: id(20), registration_id: id(20), registration_type: "operating_notice",
  context_key: `operating-notice-${id(20)}`, shop_name: "큐멘", starts_on: `${year}-11-09`, ends_on: `${year}-11-09`,
  message: "개인사정으로 가게 하루만 쉬어가요 손님..죄송합니다🙇‍♂️", ...overrides });
const render = (facts, flags = {}) => buildPublicationPayload({ notificationId: id(5), facts, protocol: 2, sourceUrl: source.url, ...flags });

test("큐멘 실제 공지 회귀: 원문을 보존하고 임시휴무 한 문장과 유형 제목을 보낸다", () => {
  const notice = automatic();
  const before = structuredClone(notice);
  const payload = render([notice]);
  assert.deepEqual(payload.notification, { title: "임시휴무 안내", body: "큐멘은 11월 9일 하루 쉬어요." });
  assert.deepEqual(notice, before);
  assert.equal(payload.notification.body.includes(notice.message), false);
  assert.deepEqual(JSON.parse(payload.data.deep_link), { version: 2, action: "operating_notices", notice_id: id(20) });
});
test("매장명의 받침과 월을 넘는 날짜를 유지하고 추측한 사유는 넣지 않는다", () => {
  assert.equal(automaticOperatingNoticeCopy(automatic({ shop_name: "멘코지" })).body, "멘코지는 11월 9일 하루 쉬어요.");
  assert.equal(automaticOperatingNoticeCopy(automatic({ starts_on: `${year}-10-31`, ends_on: `${year}-11-02` })).body,
    "큐멘은 10월 31일부터 11월 2일까지 쉬어요.");
  const crossing = automaticOperatingNoticeCopy(automatic({ starts_on: "2026-12-31", ends_on: "2027-01-02" }));
  assert.equal(crossing.body, "큐멘은 2026년 12월 31일부터 2027년 1월 2일까지 쉬어요.");
});
test("명확한 영업 종료와 단축 영업은 확정된 마감 시각만 문장으로 만든다", () => {
  const close = automatic({ type_id: "early_closing", time_meaning: "closing", ends_at: "16:30", message: "금일 조기마감합니다" });
  assert.deepEqual(render([close]).notification, { title: "조기 마감 안내", body: "큐멘은 11월 9일 16시 30분에 일찍 마감해요." });
  assert.throws(() => render([{ ...close, message: "15시에 마감합니다" }]), /operating_notice_copy_review_required/);
  assert.equal(render([{ ...close, message: "16시 30분 마감합니다" }]).notification.body, "큐멘은 11월 9일 16시 30분에 일찍 마감해요.");
  const shorter = { ...close, type_id: "shortened_hours", ends_at: "16:00" };
  assert.deepEqual(render([shorter]).notification, { title: "단축 영업 안내", body: "큐멘은 11월 9일 16시까지 영업해요." });
});
test("부분 휴무와 마지막 주문, 예정, 예외, 읽는 법이 미정인 상호는 자동 발송하지 않는다", () => {
  for (const message of ["저녁부터 휴무", "점심만 영업", "마지막 주문 14시", "라스트오더 14시", "웨이팅 마감", "대기 손님까지", "내일 재개 예정", "10일 제외", "영업시간 변경", "휴무 취소", "14시부터 휴무", "14:00~16:00 휴무", "14시 휴무"]) {
    assert.throws(() => previewPublication({ source, facts: [automatic({ message })] }), /operating_notice_copy_review_required/, message);
  }
  for (const overrides of [{ shop_name: "RAMEN" }, { exception_dates: [`${year}-11-09`] }, { time_meaning: "partial_day" }, { type_id: "opening_delay" }]) {
    assert.throws(() => render([automatic(overrides)]), /operating_notice_copy_review_required/);
  }
});
test("검수한 유형별 자연문은 원문이나 메타데이터를 덧붙이지 않고 그대로 사용한다", () => {
  const examples = [
    ["opening_delay", "오픈 지연 안내", "로망라멘은 11월 9일 12시에 문을 열어요."],
    ["opening_delay", "오픈 지연 안내", "멘야로지는 11월 9일 12시 30분에 문을 열 예정이에요."],
    ["early_closing", "조기 마감 안내", "큐멘은 11월 9일 영업을 16시에 마쳤어요."],
    ["shortened_hours", "단축 영업 안내", "킨카라멘은 11월 9일 점심만 영업해요."],
    ["temporary_suspension", "영업 일시 중단 안내", "멘코지는 장비 문제로 잠시 쉬어요. 저녁부터 다시 영업할 예정이에요."],
  ];
  for (const [type_id, notification_title, message] of examples) {
    const reviewed = fact({ type_id, message_format: "sentence", notification_title, message });
    validateFact(reviewed, source.url);
    assert.deepEqual(render([reviewed]).notification, { title: notification_title, body: message });
  }
});
test("검수 문구는 선택한 유형에만 포함되고 취소 문구를 휴무 원문으로 덮어쓰지 않는다", () => {
  const reviewed = fact({ message_format: "sentence", notification_title: "임시휴무 안내", message: "큐멘은 11월 9일 하루 쉬어요." });
  assert.equal(render([reviewed]).notification.body, reviewed.message);
  const cancellation = { ...reviewed, message: "큐멘의 11월 9일 휴무가 취소됐어요." };
  assert.deepEqual(render([cancellation], { cancelled: true }).notification, { title: "공지 취소 안내", body: cancellation.message });
  assert.equal(render([automatic()], { protocol: 0 }), null);
});
test("검수 문구 형식과 제목은 검증하며 기존 fragment 계약은 유지한다", () => {
  assert.throws(() => validateFact(fact({ message_format: "raw" }), source.url), /invalid_message_format/);
  assert.throws(() => validateFact(fact({ notification_title: "제목" }), source.url), /invalid_notification_title/);
  assert.throws(() => validateFact(fact({ message_format: "sentence", notification_title: "제목\n본문" }), source.url), /invalid_notification_title/);
  assert.ok(render([fact()]).notification.body.startsWith("[테스트라멘 본점 ·"));
});
