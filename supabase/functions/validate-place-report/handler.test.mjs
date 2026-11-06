import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { createPlaceValidationHandler } from "./handler.ts";
import { parsePlaceUrl, verifyPlace } from "./place_link.ts";

const secret = "11".repeat(32);
const timestamp = "1792812600";
const kakaoUrl = "https://place.map.kakao.com/1200130562";
const defaultBody = { place_url: kakaoUrl, actor_uid: null, actor_ip: "203.0.113.1" };
function html(url = kakaoUrl, title = "테스트 매장", description = "서울 마포구 테스트로 1") {
  return `<head><meta property="og:title" content="${title}"><meta property="og:description" content="${description}"><meta property="og:url" content="${url}"></head>`;
}
function harness({ provider, reservation = { allowed: true }, keyDelayMs = 0, reservationDelayMs = 0 } = {}) {
  const calls = [];
  const handler = createPlaceValidationHandler({ url: "https://db.fixture.invalid", serviceKey: "server-only-key", now: () => Number(timestamp) * 1000, fetcher: async (input, options = {}) => {
    const url = String(input);
    const body = options.body ? JSON.parse(options.body) : null;
    calls.push({ url, options, body });
    if (url.endsWith("/rpc/read_place_report_validation_key")) {
      if (keyDelayMs) await new Promise(resolve => setTimeout(resolve, keyDelayMs));
      return Response.json({ key: secret });
    }
    if (url.endsWith("/rpc/reserve_place_report_validation")) {
      if (reservationDelayMs) await new Promise(resolve => setTimeout(resolve, reservationDelayMs));
      return Response.json(reservation);
    }
    assert.equal(url.startsWith("https://db.fixture.invalid/"), false, "검증 함수는 저장 API를 호출하지 않습니다");
    if (provider) return provider(url, options);
    return new Response(html(), { headers: { "Content-Type": "text/html; charset=utf-8" } });
  } });
  return { calls, handler, invoke: (body = defaultBody, overrides = {}) => {
    const text = typeof body === "string" ? body : JSON.stringify(body);
    const signature = createHmac("sha256", Buffer.from(secret, "hex")).update(timestamp + "\n" + text).digest("hex");
    return handler(new Request("https://edge.fixture.invalid", { method: "POST", body: text, headers: {
      "Content-Type": "application/json", "x-ramap-timestamp": timestamp, "x-ramap-signature": signature, ...overrides,
    } }));
  } };
}

test("DB 서명 요청만 검증하고 저장 없이 검증된 장소 ID를 반환한다", async () => {
  const app = harness();
  const response = await app.invoke();
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { provider: "kakao", place_id: "1200130562" });
  assert.deepEqual(app.calls.map((call) => new URL(call.url).pathname), ["/rest/v1/rpc/read_place_report_validation_key", "/rest/v1/rpc/reserve_place_report_validation", "/1200130562"]);
  const headers = new Headers(app.calls.at(-1).options.headers);
  assert.equal(headers.has("Authorization"), false);
  assert.equal(headers.has("apikey"), false);
});

test("공개 API 키만으로 내부 검증 함수를 직접 사용할 수 없다", async () => {
  const app = harness();
  const response = await app.handler(new Request("https://edge.fixture.invalid", { method: "POST", body: JSON.stringify(defaultBody), headers: { Authorization: "Bearer anonymous-key" } }));
  assert.equal(response.status, 401);
  assert.equal(app.calls.length, 0);
});

for (const headers of [{ "x-ramap-signature": "00".repeat(32) }, { "x-ramap-timestamp": String(Number(timestamp) - 31) }, { "x-ramap-timestamp": String(Number(timestamp) + 31) }]) {
  test(`변조되거나 만료된 서명은 외부 검증 전에 거절한다: ${Object.keys(headers)}`, async () => {
    const app = harness();
    assert.equal((await app.invoke(defaultBody, headers)).status, 401);
    assert.equal(app.calls.some((call) => !call.url.includes("/read_place_report_validation_key")), false);
  });
}

test("서명된 본문을 바꾸면 HMAC 검증에 실패한다", async () => {
  const signature = createHmac("sha256", Buffer.from(secret, "hex")).update(timestamp + "\n" + JSON.stringify(defaultBody)).digest("hex");
  const app = harness();
  assert.equal((await app.invoke({ ...defaultBody, actor_ip: "203.0.113.9" }, { "x-ramap-signature": signature })).status, 401);
  assert.equal(app.calls.length, 1);
});

test("요청 헤더로 서명된 제보자 신원을 덮어쓰지 않는다", async () => {
  const app = harness();
  assert.equal((await app.invoke(defaultBody, { "x-forwarded-for": "203.0.113.9", "x-user-id": "forged" })).status, 200);
  assert.deepEqual(app.calls[1].body, { p_actor_uid: null, p_actor_ip: "203.0.113.1" });
});

for (const value of ["https://naver.me/test", "https://example.com/place/123", "http://place.map.kakao.com/123", "https://place.map.kakao.com:443/123", "https://place.map.kakao.com@evil.example/123", "https://place.map.kakao.com/123#x", "https://applink.map.kakao.com/place?id=123&id=456", "https://127.0.0.1/123"]) {
  test(`서명된 요청이어도 잘못된 URL은 거절한다: ${value}`, async () => {
    const app = harness();
    assert.equal((await app.invoke({ ...defaultBody, place_url: value })).status, 400);
    assert.equal(app.calls.length, 1);
  });
}

test("단축 링크의 목적지와 실제 장소 페이지를 확인한다", async () => {
  const app = harness({ provider: (url) => url.startsWith("https://kko.to/")
    ? new Response(null, { status: 301, headers: { Location: "https://applink.map.kakao.com/place?id=1200130562&t_src=share" } })
    : new Response(html(), { headers: { "Content-Type": "text/html" } }) });
  assert.equal((await app.invoke({ ...defaultBody, place_url: "https://kko.to/i2sQooNyPb" })).status, 200);
  assert.equal(app.calls.length, 4);
});

function naverPlaceResponse(detail = { name: "코요라멘", address: { roadAddress: "경기 용인시 기흥구 동백중앙로 245" }, coordinate: { longitude: 127.1514632, latitude: 37.2758513 } }) {
  return Response.json({ data: { placeDetail: detail } });
}

test("네이버 단축 링크를 해석한 장소 ID로 실제 장소 정보를 조회한다", async () => {
  const target = "https://m.place.naver.com/restaurant/1014196740/home";
  const app = harness({ provider: (url) => url.startsWith("https://naver.me/")
    ? new Response(null, { status: 307, headers: { Location: target } })
    : naverPlaceResponse() });
  const response = await app.invoke({ ...defaultBody, place_url: "https://naver.me/Ga2HR1BU" });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { provider: "naver", place_id: "1014196740" });
  assert.equal(app.calls.at(-1).url, "https://map.naver.com/p/api/place/directionsPOI/1014196740");
});

test("제보 실패가 발생한 네이버 지도 링크의 장소 ID를 검증한다", async () => {
  const app = harness({ provider: () => naverPlaceResponse() });
  const response = await app.invoke({ ...defaultBody, place_url: "https://map.naver.com/p/entry/place/1690614480" });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { provider: "naver", place_id: "1690614480" });
  assert.equal(app.calls.at(-1).url, "https://map.naver.com/p/api/place/directionsPOI/1690614480");
  assert.equal(new Headers(app.calls.at(-1).options.headers).get("Referer"), "https://map.naver.com/");
});

test("네이버가 HTTP 200과 빈 장소 정보를 반환해도 존재하는 매장으로 인정하지 않는다", async () => {
  const app = harness({ provider: () => naverPlaceResponse({ name: null, address: null, coordinate: null }) });
  assert.equal((await app.invoke({ ...defaultBody, place_url: "https://map.naver.com/p/entry/place/999999999" })).status, 400);
});

for (const detail of [null, {}, { name: "가짜", address: null, coordinate: null }, { name: "가짜", address: { address: "서울" }, coordinate: { longitude: 999, latitude: 37 } }]) {
  test(`네이버 장소 응답이 불완전하면 검증 성공으로 처리하지 않는다: ${JSON.stringify(detail)}`, async () => {
    const app = harness({ provider: () => naverPlaceResponse(detail) });
    assert.equal((await app.invoke({ ...defaultBody, place_url: "https://map.naver.com/p/entry/place/1690614480" })).status, 503);
  });
}

for (const status of [302, 403, 429, 500]) {
  test(`네이버 조회 제한과 리다이렉트를 검증 성공으로 처리하지 않는다: ${status}`, async () => {
    const app = harness({ provider: () => new Response(null, { status, headers: { Location: "https://evil.example/" } }) });
    assert.equal((await app.invoke({ ...defaultBody, place_url: "https://map.naver.com/p/entry/place/1690614480" })).status, 503);
    assert.equal(app.calls.length, status === 429 || status === 500 ? 5 : 3);
  });
}

for (const target of ["http://place.map.kakao.com/123", "https://evil.example/123", "https://127.0.0.1/123", "https://map.naver.com/p?title=가짜매장"]) {
  test(`허용하지 않은 리다이렉트 목적지에는 요청하지 않는다: ${target}`, async () => {
    const app = harness({ provider: () => new Response(null, { status: 302, headers: { Location: new URL(target).toString() } }) });
    assert.equal((await app.invoke({ ...defaultBody, place_url: "https://naver.me/Ga2HR1BU" })).status, 400);
    assert.equal(app.calls.length, 3);
  });
}

for (const status of [400, 404, 410]) {
  test(`없는 장소는 거절한다: ${status}`, async () => {
    const app = harness({ provider: () => new Response(null, { status }) });
    assert.equal((await app.invoke()).status, 400);
  });
}

for (const status of [403, 429, 500]) {
  test(`외부 장애는 일시 검증 실패로 전달한다: ${status}`, async () => {
    const app = harness({ provider: () => new Response(null, { status }) });
    const response = await app.invoke();
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("Retry-After"), "30");
  });
}

for (const content of [html(kakaoUrl, "카카오맵"), html("https://place.map.kakao.com/999"), "<html>captcha</html>", html(kakaoUrl, "", "")]) {
  test(`HTTP 200이어도 장소 정보가 없거나 다르면 인정하지 않는다: ${content.slice(0, 50)}`, async () => {
    const app = harness({ provider: () => new Response(content, { headers: { "Content-Type": "text/html" } }) });
    assert.equal((await app.invoke()).status, 503);
  });
}

test("외부 요청 시간 초과에는 성공 결과를 반환하지 않는다", async () => {
  const app = harness({ provider: () => { throw new DOMException("Timeout", "TimeoutError"); } });
  assert.equal((await app.invoke()).status, 503);
});

test("검증 한도 초과 시 외부 요청을 시작하지 않는다", async () => {
  const app = harness({ reservation: { allowed: false, status: 429, retry_after_seconds: 60 } });
  const response = await app.invoke();
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("Retry-After"), "60");
  assert.equal(app.calls.length, 2);
});

test("검증용 키는 짧게 캐시하며 외부 서비스로 보내지 않는다", async () => {
  const app = harness();
  assert.equal((await app.invoke()).status, 200);
  assert.equal((await app.invoke()).status, 200);
  assert.equal(app.calls.filter((call) => call.url.endsWith("/read_place_report_validation_key")).length, 1);
});

test("잘못된 본문은 검증하지 않는다", async () => {
  const app = harness();
  assert.equal((await app.invoke("{")).status, 400);
  assert.equal((await app.invoke({ ...defaultBody, verified: true })).status, 400);
  assert.equal((await app.invoke("x".repeat(8193))).status, 413);
});

test("리다이렉트 반복은 제한된 요청 안에서 중단한다", async () => {
  let calls = 0;
  await assert.rejects(verifyPlace(parsePlaceUrl("https://naver.me/Ga2HR1BU"), async () => {
    calls++;
    return new Response(null, { status: 302, headers: { Location: "https://naver.me/Ga2HR1BU" } });
  }, new AbortController().signal), (error) => error.status === 400);
  assert.equal(calls, 3);
});

test("네이버의 일시적인 429는 한 요청 안에서 재검증하고 실제 장소를 확인한 뒤 성공한다", async () => {
  let attempts = 0;
  const app = harness({ provider: () => ++attempts === 1
    ? new Response(null, { status: 429 }) : naverPlaceResponse() });
  assert.equal((await app.invoke({ ...defaultBody, place_url: "https://map.naver.com/p/entry/place/1690614480" })).status, 200);
  assert.equal(attempts, 2);
  assert.equal(app.calls.filter(call => call.url.endsWith("/reserve_place_report_validation")).length, 1);
});

test("실기기에서 발생한 연속 두 번의 네이버 429도 한 요청 안에서 복구한다", async () => {
  let attempts = 0;
  const app = harness({ provider: () => ++attempts <= 2
    ? new Response(null, { status: 429 }) : naverPlaceResponse() });
  assert.equal((await app.invoke({ ...defaultBody, place_url: "https://map.naver.com/p/entry/place/1690614480" })).status, 200);
  assert.equal(attempts, 3);
  assert.equal(app.calls.filter(call => call.url.endsWith("/reserve_place_report_validation")).length, 1);
});

test("네이버 단축 링크의 일시적인 통신 오류도 서버 안에서 한 번 재시도한다", async () => {
  let attempts = 0;
  const app = harness({ provider: url => {
    if (url.startsWith("https://naver.me/")) {
      if (++attempts === 1) throw new TypeError("network failed");
      return new Response(null, { status: 302, headers: { Location: "https://map.naver.com/p/entry/place/1690614480" } });
    }
    return naverPlaceResponse();
  } });
  assert.equal((await app.invoke({ ...defaultBody, place_url: "https://naver.me/GqfbPYBM" })).status, 200);
  assert.equal(attempts, 2);
});

test("외부 서비스가 긴 Retry-After를 지정하면 조기에 재시도하지 않는다", async () => {
  const app = harness({ provider: () => new Response(null, { status: 429, headers: { "Retry-After": "30" } }) });
  assert.equal((await app.invoke()).status, 503);
  assert.equal(app.calls.length, 3);
});

test("키 조회와 요청 한도 확인 때문에 기존 1.8초를 넘겨도 정상 검증을 완료한다", async () => {
  const app = harness({ keyDelayMs: 700, reservationDelayMs: 700, provider: async () => {
    await new Promise(resolve => setTimeout(resolve, 800));
    return naverPlaceResponse();
  } });
  assert.equal((await app.invoke({ ...defaultBody, place_url: "https://map.naver.com/p/entry/place/1690614480" })).status, 200);
});

test("인증 전 느린 본문도 요청 취소 시 즉시 읽기를 중단한다", async () => {
  const app = harness();
  let cancelled = false;
  const body = new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode("{")); }, cancel() { cancelled = true; } });
  const request = new Request("https://edge.fixture.invalid", {
    method: "POST", body, duplex: "half", signal: AbortSignal.timeout(30),
    headers: { "x-ramap-timestamp": timestamp, "x-ramap-signature": "00".repeat(32) },
  });
  const response = await app.handler(request);
  assert.equal(response.status, 503);
  assert.equal(cancelled, true);
  assert.equal(app.calls.length, 0);
});

test("단축 링크 응답의 정리 작업이 끝나지 않아도 목적지 검증을 진행한다", async () => {
  const app = harness({ provider: url => url.startsWith("https://naver.me/")
    ? new Response(new ReadableStream({ cancel() { return new Promise(() => {}); } }), {
      status: 302, headers: { Location: "https://map.naver.com/p/entry/place/1690614480" },
    }) : naverPlaceResponse() });
  const response = await app.invoke({ ...defaultBody, place_url: "https://naver.me/GqfbPYBM" });
  assert.equal(response.status, 200);
});

test("장소 메타데이터를 확인한 뒤 응답 정리 작업 때문에 성공이 지연되지 않는다", async () => {
  const app = harness({ provider: () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode(html())); },
    cancel() { return new Promise(() => {}); },
  }), { headers: { "Content-Type": "text/html" } }) });
  assert.equal((await app.invoke()).status, 200);
});
