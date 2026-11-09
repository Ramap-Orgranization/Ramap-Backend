export const id = (number) => `00000000-0000-4000-8000-${String(number).padStart(12, "0")}`;
export const source = { url: "https://www.instagram.com/p/verified-source/", raw_text: "검증 전 원문과 내부 메모는 발송 본문에 포함하지 않는다", official_verified: true };
export function fact(overrides = {}) {
  return { id: id(1), shop_id: id(2), shop_name: "테스트라멘 본점", type_id: "temporary_closure", verified: true, certainty: "confirmed", starts_on: "2026-11-12", ends_on: "2026-11-12", starts_at: null, ends_at: null, time_meaning: "full_day", exception_dates: [], message: "임시휴무", context_key: "november-notice", destination: { version: 1, action: "operating_notices" }, registration_type: "none", registration_id: null, ...overrides };
}
export function eventFact(overrides = {}) {
  return fact({ id: id(3), type_id: "event", time_meaning: "unspecified", message: "한정 메뉴 행사", destination: { version: 1, action: "event_detail", event_id: id(4) }, registration_type: "event", registration_id: id(4), ...overrides });
}
export function claim(overrides = {}) {
  return { delivery_id: id(5), claim_token: id(6), announcement_id: id(7), revision: 1, registration_identifier: "test-token", user_id: id(8), target_type: "token", supported_protocol_version: 1, facts: [fact()], source_url: source.url, kind: "initial", ...overrides };
}
