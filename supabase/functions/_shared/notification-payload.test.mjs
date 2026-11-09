import assert from "node:assert/strict";
import test from "node:test";
import { buildPublicationPayload, validOfficialUrl, validateFact } from "./notification-payload.ts";
import { previewPublication, validatePublicationDocument } from "./notification-publication.ts";
import { id, source, fact, eventFact } from "./notification-fixtures.mjs";
const render = (facts, protocol = 1) => buildPublicationPayload({ notificationId: id(5), facts, protocol, sourceUrl: source.url });

test("선택한 사실 교집합만 발송하며 원문과 다른 유형 사실은 포함하지 않는다", () => {
  const closure = fact(), event = eventFact();
  assert.equal(render([closure]).notification.body.includes(event.message), false);
  assert.equal(render([event]).notification.body.includes(closure.message), false);
  assert.equal(render([closure, event]).notification.body.includes(source.raw_text), false);
  assert.equal(render([closure, closure]).notification.body.split(closure.message).length, 2);
  assert.equal(JSON.parse(render([closure, event]).data.deep_link).action, "none");
});
test("구형 기기는 이벤트만 받으며 운영 명령이나 복합 내용이 새지 않는다", () => {
  assert.equal(render([fact()], 0), null);
  const payload = render([fact(), eventFact()], 0);
  assert.equal(payload.notification.body.includes("임시휴무"), false);
  assert.equal(payload.data.deep_link, `ramap://notification/event?event_id=${id(4)}`);
  assert.equal(payload.data.notification_type, "new_event");
});
test("월간 휴무의 떨어진 날짜를 연속 기간으로 합치지 않는다", () => {
  const payload = render([fact(), fact({ id: id(9), starts_on: "2026-11-28", ends_on: "2026-11-28" })]);
  assert.ok(payload.notification.body.includes("2026-11-12"));
  assert.ok(payload.notification.body.includes("2026-11-28"));
  assert.equal(payload.notification.body.includes("2026-11-12 ~ 2026-11-28"), false);
});
test("부타노맥스 저녁부터 휴무와 이후 종일 휴무는 별도 발행을 요구한다", () => {
  assert.throws(() => render([fact({ starts_on: "2026-10-01", ends_on: "2026-10-01", time_meaning: "partial_day", message: "저녁 휴무" }), fact({ id: id(9), starts_on: "2026-10-02", ends_on: "2026-10-05" })]), /split_required/);
});
test("라스트오더와 웨이팅 종료를 마감으로 바꾸지 않고 미스혼 날짜별 맥락은 분리한다", () => {
  const lastOrder = fact({ type_id: "shortened_hours", time_meaning: "last_order", ends_at: "14:00", message: "점심 라스트오더" });
  const waitlist = fact({ id: id(9), time_meaning: "waitlist_end", ends_at: "13:00", message: "접수 종료" });
  const payload = render([lastOrder, waitlist]);
  assert.ok(payload.notification.body.includes("라스트오더 14:00"));
  assert.ok(payload.notification.body.includes("웨이팅 접수 종료 13:00"));
  assert.equal(payload.notification.body.includes("마감"), false);
  assert.throws(() => render([lastOrder, eventFact({ starts_on: "2026-11-13", ends_on: "2026-11-13" })]), /split_required/);
});
test("정정 사실은 새 범위만 렌더링하고 이전 날짜를 합집합으로 남기지 않는다", () => {
  const payload = render([fact({ starts_on: "2026-11-15", ends_on: "2026-11-17", exception_dates: ["2026-11-16"] })]);
  assert.ok(payload.notification.body.includes("2026-11-15 ~ 2026-11-17"));
  assert.ok(payload.notification.body.includes("제외 2026-11-16"));
  assert.equal(payload.notification.body.includes("2026-11-12"), false);
});
test("미검증과 미정 사실은 초안에만 남고 발송 payload가 되지 않는다", () => {
  assert.equal(render([fact({ verified: false })]), null);
  assert.equal(render([fact({ certainty: "unknown" })]), null);
  assert.deepEqual(previewPublication({ source, facts: [fact({ certainty: "unknown" })] }).unknown_fact_ids, [id(1)]);
});
test("공식 HTTPS 출처와 동일한 링크만 허용하고 위험한 URL을 거절한다", () => {
  assert.equal(validOfficialUrl(source.url), true);
  assert.equal(validOfficialUrl("https://ramen.example.com/news"), true);
  for (const url of ["javascript:alert(1)", "intent://x", "file:///tmp/x", "tel:123", "https://user@instagram.com", "https://127.0.0.1", "https://localhost", "https://x.local", "https://x.test", "https://instagram.com:444/a", "https://instagram.com/#x", "https://instagram.com/%250a", "https://instagram.com/%0a", "https://instagram.com/\\a", "https://instagram.com/%zz"]) assert.equal(validOfficialUrl(url), false, url);
  assert.throws(() => validateFact(fact({ destination: { version: 1, action: "external_url", url: "https://other.example.com" } }), source.url), /invalid_destination/);
});
test("큰 사실 묶음은 사실을 자르지 않고 preview에서 거절한다", () => {
  const facts = Array.from({ length: 12 }, (_, index) => fact({ id: id(index + 10), message: "긴 안내".repeat(60) }));
  assert.throws(() => previewPublication(validatePublicationDocument({ source, facts })), /too_large/);
});
test('full-day event and next-day closure cannot use monthly closure exemption', () => {
  assert.throws(() => render([eventFact(), fact({ starts_on: '2026-11-13', ends_on: '2026-11-13' })]), /split_required/);
});
test('first evening closure payload preserves exact day-part without invented clock or reduced operation', () => {
  const payload = render([fact({ starts_on: '2026-10-01', ends_on: '2026-10-01', time_meaning: 'partial_day', message: '10월 1일 저녁 휴무' })]);
  assert.ok(payload.notification.body.includes('10월 1일 저녁 휴무'));
  assert.equal(payload.notification.body.includes('부분 영업'), false);
  assert.equal(payload.notification.body.includes('18:00'), false);
});
test('same canonical event cannot appear twice under different fact identities', () => {
  assert.throws(() => validatePublicationDocument({ source, facts: [eventFact(), eventFact({ id: id(19) })] }), /duplicate_event_fact/);
});

 test("protocol 2 opens the registered notice while protocol 1 keeps the list", () => {
  const notice = fact({ registration_type: "operating_notice", registration_id: id(20) });
  assert.deepEqual(JSON.parse(render([notice], 2).data.deep_link), { version: 2, action: "operating_notices", notice_id: id(20) });
  assert.deepEqual(JSON.parse(render([notice], 1).data.deep_link), { version: 1, action: "operating_notices" });
  assert.equal(render([notice], 0), null);
 });
 test("multiple notices and unregistered facts retain the list destination", () => {
  const notice = fact({ registration_type: "operating_notice", registration_id: id(20) });
  const second = fact({ id: id(21), registration_type: "operating_notice", registration_id: id(22) });
  for (const facts of [[notice, second], [fact()], [notice, fact({ id: id(23) })]]) {
    assert.deepEqual(JSON.parse(render(facts, 2).data.deep_link), { version: 1, action: "operating_notices" });
  }
 });
