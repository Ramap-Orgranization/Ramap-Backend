import { deepStrictEqual, strictEqual } from "node:assert/strict";
import { extractNaverPlaceId } from "../functions/place-search/place_search.ts";
import { extractKakaoPlaceId } from "../functions/kakao-importation/importation.ts";

type Handler = (request: Request) => Promise<Response>;
const DATABASE_URL = "https://schema-test.invalid";
const visibleShop = {
  id: "visible-shop",
  name: "등록된 가게",
  address: "검증용 주소",
  lat: 37,
  lng: 127,
  naver_place_url: "https://map.naver.com/p/entry/place/123456789",
  kakao_place_url: "https://place.map.kakao.com/987654321",
};

async function withHandler(
  slug: string,
  verify: (handler: Handler, requests: URL[]) => Promise<void>,
) {
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  const originalEnv = Object.getOwnPropertyDescriptor(Deno.env, "get")!;
  const originalFetch = globalThis.fetch;
  const requests: URL[] = [];
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", {
    configurable: true, writable: true, enumerable: originalServe.enumerable,
    value: (callback: Handler) => { handler = callback; },
  });
  Object.defineProperty(Deno.env, "get", {
    configurable: true, writable: true, enumerable: originalEnv.enumerable,
    value: (name: string) => name === "SUPABASE_URL" ? DATABASE_URL : "fixture-only",
  });
  globalThis.fetch = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : input.toString());
    requests.push(url);
    if (url.origin === DATABASE_URL && url.pathname === "/auth/v1/user") {
      const authorized = new Headers(init?.headers).get("Authorization") === "Bearer test-user";
      return Response.json(authorized ? { id: "fixture-user" } : {}, { status: authorized ? 200 : 401 });
    }
    if (url.origin === DATABASE_URL && url.pathname === "/rest/v1/ramen_shops") {
      strictEqual(url.searchParams.get("is_visible"), "eq.true");
      const column = slug === "place-search" ? "naver_place_url" : "kakao_place_url";
      deepStrictEqual(url.searchParams.get("select")?.split(","), ["id", column, "name", "address", "lat", "lng"]);
      return Response.json([visibleShop]);
    }
    if (slug === "place-search" && url.origin === DATABASE_URL && url.pathname === "/rest/v1/rpc/consume_place_search_budget") {
      return Response.json({ allowed: true });
    }
    if (url.hostname === "openapi.naver.com") {
      return Response.json({ items: [{
        title: "이름이 다른 외부 가게",
        address: "외부 주소",
        category: "음식점",
        mapx: "1260000000",
        mapy: "360000000",
        link: "https://m.place.naver.com/restaurant/123456789/home",
      }] });
    }
    if (url.hostname === "map.kakao.com") {
      return Response.json({ favorites: [{ type: "PLACE", key: "987654321", display1: "이름이 다른 외부 가게", display2: "외부 주소" }] });
    }
    throw new Error("Unexpected outbound request in schema regression test");
  };
  try {
    await import(new URL(`../functions/${slug}/index.ts?schema-test-${crypto.randomUUID()}`, import.meta.url).href);
    strictEqual(typeof handler, "function");
    await verify(handler!, requests);
  } finally {
    Object.defineProperty(Deno, "serve", originalServe);
    Object.defineProperty(Deno.env, "get", originalEnv);
    globalThis.fetch = originalFetch;
  }
}

function post(body: unknown, token = "test-user") {
  return new Request("https://handler-test.invalid", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}

Deno.test("place search queries current schema and matches Naver URL ID despite different name and position", async () => {
  await withHandler("place-search", async (handler, requests) => {
    const result = await handler(post({ query: "테스트 라멘", center: { lat: 37, lng: 127 } }));
    strictEqual(result.status, 200);
    deepStrictEqual(await result.json(), { results: [{
      name: visibleShop.name, address: visibleShop.address, lat: 37, lng: 127,
      kind: "registered_shop", shop_id: visibleShop.id,
    }] });
    strictEqual(requests.filter((url) => url.pathname === "/rest/v1/ramen_shops").length, 1);
  });
});

Deno.test("Kakao import queries current schema and preserves the app response with URL ID matching", async () => {
  await withHandler("kakao-importation", async (handler) => {
    const result = await handler(post({ url: "https://map.kakao.com/?folderid=12345" }));
    strictEqual(result.status, 200);
    deepStrictEqual(await result.json(), {
      provider: "kakao", totalPlaceCount: 1, matchedShopIds: [visibleShop.id], unmatchedPlaceNames: [],
    });
  });
});

Deno.test("Naver import matching queries current schema and preserves address matching and unmatched results", async () => {
  await withHandler("importation-match", async (handler) => {
    const result = await handler(post({ provider: "naver", places: [
      { name: "외부 표기", address: visibleShop.address },
      { name: "없는 가게", address: "없는 주소" },
    ] }));
    strictEqual(result.status, 200);
    deepStrictEqual(await result.json(), {
      provider: "naver", totalPlaceCount: 2, matchedShopIds: [visibleShop.id], unmatchedPlaceNames: ["없는 가게"],
    });
  });
});

for (const slug of ["kakao-importation", "importation-match"]) {
  Deno.test(`${slug} still rejects missing and invalid user tokens before any database or provider lookup`, async () => {
    await withHandler(slug, async (handler, requests) => {
      for (const token of ["", "invalid-user"]) {
        const result = await handler(post({}, token));
        strictEqual(result.status, 401);
        deepStrictEqual(await result.json(), { code: "authentication_required" });
      }
      strictEqual(requests.some((url) => url.pathname.startsWith("/rest/") || url.origin !== DATABASE_URL), false);
    });
  });
}

Deno.test("Naver URL extraction covers current desktop and mobile forms and absent IDs", () => {
  for (const url of [
    "https://map.naver.com/p/entry/place/123456789",
    "https://m.place.naver.com/restaurant/123456789/home?entry=plt",
    "https://pcmap.place.naver.com/restaurant/123456789/home",
  ]) strictEqual(extractNaverPlaceId(url), "123456789");
  for (const value of [null, undefined, "", "invalid-url", "https://map.naver.com/"]) {
    strictEqual(extractNaverPlaceId(value), null);
  }
});

Deno.test("Kakao URL extraction tolerates URL suffixes and missing values without matching foreign hosts", () => {
  for (const url of ["https://place.map.kakao.com/987654321", " https://place.map.kakao.com/987654321?from=map "]) {
    strictEqual(extractKakaoPlaceId(url), "987654321");
  }
  for (const value of [null, undefined, "", "https://example.invalid/987654321"]) {
    strictEqual(extractKakaoPlaceId(value), undefined);
  }
});
