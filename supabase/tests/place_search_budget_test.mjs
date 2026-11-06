import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { SearchBudget, searchActorKey } from "../functions/place-search/search_budget.ts";

const originalFetch = globalThis.fetch;
const originalDeno = globalThis.Deno;
const originalNow = Date.now;
afterEach(() => { globalThis.fetch = originalFetch; globalThis.Deno = originalDeno; Date.now = originalNow; });

const shop = { id: "fixture-shop", naver_place_url: "https://m.place.naver.com/restaurant/123456789/home", name: "테스트 가게", address: "테스트 주소", lat: 37, lng: 127 };
const item = { title: "외부 이름", address: "외부 주소", category: "음식점", mapx: "1270000000", mapy: "370000000", link: shop.naver_place_url };
const searchBody = { query: "테스트 라멘", center: { lat: 37, lng: 127 } };

async function fixture(reserve = () => ({ allowed: true }), providerStatus = 200) {
  const url = `https://${crypto.randomUUID()}.fixture.invalid`;
  const requests = [];
  let handler;
  globalThis.Deno = { serve: (callback) => { handler = callback; }, env: { get: (name) => name === "SUPABASE_URL" ? url : "fixture-only" } };
  globalThis.fetch = async (input, options = {}) => {
    const target = new URL(input.toString());
    const body = options.body ? JSON.parse(options.body) : null;
    requests.push({ host: target.hostname, path: target.pathname, body, options });
    if (target.origin === url && target.pathname === "/rest/v1/rpc/consume_place_search_budget") return Response.json(reserve(body, requests));
    if (target.origin === url && target.pathname === "/rest/v1/ramen_shops") {
      assert.equal(target.searchParams.get("is_visible"), "eq.true");
      return Response.json([shop]);
    }
    if (target.hostname === "openapi.naver.com") return Response.json({ items: [item] }, { status: providerStatus });
    if (target.hostname === "maps.apigw.ntruss.com") return Response.json({ status: "OK", addresses: [{ x: "127", y: "37", roadAddress: "테스트 주소" }] }, { status: providerStatus });
    throw new Error("Unexpected outbound request");
  };
  await import(new URL(`../functions/place-search/index.ts?budget-test-${crypto.randomUUID()}`, import.meta.url).href);
  return { handler, requests, url };
}
function post(body = searchBody, headers = {}) {
  return new Request("https://handler-test.invalid", { method: "POST", headers: { "Content-Type": "application/json", "x-forwarded-for": "198.51.100.1", ...headers }, body: JSON.stringify(body) });
}
const providers = (requests) => requests.filter((r) => ["openapi.naver.com", "maps.apigw.ntruss.com"].includes(r.host));
const claims = (requests) => requests.filter((r) => r.path.endsWith("consume_place_search_budget"));
const denial = (scope = "global", reason = "limit") => ({ allowed: false, scope, reason, retry_after_seconds: 300 });

test("normal search preserves visible shop matching and reserves before the provider", async () => {
  const f = await fixture();
  const response = await f.handler(post());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { results: [{ name: shop.name, address: shop.address, lat: 37, lng: 127, kind: "registered_shop", shop_id: shop.id }] });
  assert.deepEqual(claims(f.requests).map((r) => r.body.p_kind), ["request", "naver_local", "naver_local"]);
  assert.equal(f.requests[2].host, "openapi.naver.com");
  assert.equal(providers(f.requests)[0].options.redirect, "error");
  assert.ok(providers(f.requests)[0].options.signal instanceof AbortSignal);
});
test("a second station-alias lookup consumes a second provider unit", async () => {
  const f = await fixture();
  assert.equal((await f.handler(post({ ...searchBody, query: "테스트라멘" }))).status, 200);
  assert.equal(providers(f.requests).length, 2);
  assert.deepEqual(claims(f.requests).map((r) => r.body.p_kind), ["request", "naver_local", "naver_local"]);
});
test("request limits reject before any provider or shop lookup and return Retry-After", async () => {
  const f = await fixture(() => denial("client"));
  const response = await f.handler(post());
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("Retry-After"), "300");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(providers(f.requests).length, 0);
  assert.equal(f.requests.length, 1);
});
test("provider limits reject before the limited provider is called", async () => {
  const f = await fixture((body) => body.p_kind === "request" ? { allowed: true } : denial());
  assert.equal((await f.handler(post())).status, 429);
  assert.equal(providers(f.requests).length, 0);
});
test("geocoding budget denials propagate instead of becoming an empty successful response", async () => {
  const f = await fixture((body) => body.p_kind === "naver_geocoding" ? denial() : { allowed: true });
  const response = await f.handler(post({ ...searchBody, query: "서울특별시 강남구 테헤란로 123" }));
  assert.equal(response.status, 429);
  assert.equal(providers(f.requests).length, 0);
});
test("geocoding consumes its own budget and preserves its result contract", async () => {
  const f = await fixture();
  const response = await f.handler(post({ ...searchBody, query: "서울특별시 강남구 테헤란로 123" }));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).results[0].kind, "map_location");
  assert.deepEqual(claims(f.requests).map((r) => r.body.p_kind), ["request", "naver_geocoding"]);
});
test("quota backend failures fail closed for both local search and geocoding", async () => {
  for (const query of [searchBody.query, "서울특별시 강남구 테헤란로 123"]) {
    const f = await fixture((body) => body.p_kind === "request" ? { allowed: true } : { error: "unavailable" });
    assert.equal((await f.handler(post({ ...searchBody, query }))).status, 503);
    assert.equal(providers(f.requests).length, 0);
  }
});
test("the initial quota failure and a disabled budget never call providers", async () => {
  for (const result of [{}, denial("global", "disabled")]) {
    const f = await fixture(() => result);
    assert.equal((await f.handler(post())).status, 503);
    assert.equal(providers(f.requests).length, 0);
  }
});
test("failed provider attempts still reserve a unit and do not retry", async () => {
  const f = await fixture(undefined, 500);
  assert.equal((await f.handler(post())).status, 502);
  assert.equal(providers(f.requests).length, 1);
  assert.equal(claims(f.requests).filter((r) => r.body.p_kind === "naver_local").length, 1);
});
test("the second lookup cannot exceed its quota after the first has succeeded", async () => {
  let local = 0;
  const f = await fixture((body) => body.p_kind !== "naver_local" || ++local === 1 ? { allowed: true } : denial());
  assert.equal((await f.handler(post({ ...searchBody, query: "테스트라멘" }))).status, 429);
  assert.equal(providers(f.requests).length, 1);
});
test("invalid, oversized and unsupported requests spend no quota or provider calls", async () => {
  const f = await fixture();
  assert.equal((await f.handler(post({}))).status, 400);
  assert.equal((await f.handler(new Request("https://handler-test.invalid"))).status, 405);
  assert.equal((await f.handler(post({ ...searchBody, padding: "a".repeat(5000) }))).status, 413);
  assert.equal(f.requests.length, 0);
});
test("rotating tokens and spoofed actor payloads do not change the client key", async () => {
  const f = await fixture();
  await f.handler(post({ ...searchBody, actor_key: "forged-A" }, { Authorization: "Bearer token-A" }));
  await f.handler(post({ ...searchBody, actor_key: "forged-B" }, { Authorization: "Bearer token-B" }));
  const actors = claims(f.requests).filter((r) => r.body.p_kind === "request").map((r) => r.body.p_actor_key);
  assert.equal(actors[0], actors[1]);
  assert.match(actors[0], /^[a-f0-9]{64}$/);
  assert.ok(!JSON.stringify(actors).includes("198.51.100.1"));
});
test("global denial cache also blocks different client keys and expires within 30 seconds", async () => {
  const f = await fixture(() => denial());
  let now = Date.now();
  Date.now = () => now;
  const first = new SearchBudget(f.url, "fixture-only", "a".repeat(64));
  const second = new SearchBudget(f.url, "fixture-only", "b".repeat(64));
  await assert.rejects(() => first.reserve("request"), (e) => e.status === 429);
  await assert.rejects(() => second.reserve("request"), (e) => e.status === 429);
  assert.equal(claims(f.requests).length, 1);
  now += 31_000;
  await assert.rejects(() => second.reserve("request"), (e) => e.status === 429);
  assert.equal(claims(f.requests).length, 2);
});
test("the client key uses a keyed digest and the closest forwarded address", async () => {
  const same = await searchActorKey(post(), "fixture-key");
  assert.equal(same, await searchActorKey(post({}, { "x-forwarded-for": "spoofed, 198.51.100.1" }), "fixture-key"));
  assert.notEqual(same, await searchActorKey(post(), "different-fixture-key"));
});

test("quota windows and wait times survive the Edge response and denial cache", async () => {
  for (const window of ["minute", "hour", "day"]) {
    const f = await fixture(() => ({ ...denial(), window }));
    for (let attempt = 0; attempt < 2; attempt++) {
      const response = await f.handler(post());
      const body = await response.json();
      assert.equal(response.status, 429);
      assert.equal(body.limit_window, window);
      assert.equal(body.retry_after_seconds, Number(response.headers.get("Retry-After")));
    }
    assert.equal(claims(f.requests).length, 1);
    assert.equal(providers(f.requests).length, 0);
  }
});
test("disabled budgets expose a wait time without a false daily limit", async () => {
  const f = await fixture(() => denial("global", "disabled"));
  const response = await f.handler(post());
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "Search temporarily limited", code: "search_budget_unavailable", retry_after_seconds: 300, limit_window: null });
});
test("unknown quota window metadata fails closed", async () => {
  const f = await fixture(() => ({ ...denial(), window: "unknown" }));
  assert.equal((await f.handler(post())).status, 503);
  assert.equal(providers(f.requests).length, 0);
});
