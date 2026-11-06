import { extractNaverPlaceId, MAX_RESULTS, parseInput, searchPlaces } from "./place_search.ts";
import type { RegisteredShop } from "./place_search.ts";
import { SearchBudget, SearchBudgetError, searchActorKey } from "./search_budget.ts";

const JSON_HEADERS = { "Content-Type": "application/json; charset=utf-8" };
const NAVER_LOCAL_SEARCH_URL = "https://openapi.naver.com/v1/search/local.json";
const NAVER_GEOCODING_URL = "https://maps.apigw.ntruss.com/map-geocode/v2/geocode";

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  const parsed = await readSearchBody(request);
  if (parsed.tooLarge) return jsonResponse(413, { error: "Invalid search request", code: "search_request_too_large" });
  const body = parsed.body;
  const input = parseInput(body);
  if (input === null) {
    return jsonResponse(400, { error: "Invalid search request" });
  }

  const clientId = Deno.env.get("NAVER_SEARCH_CLIENT_ID");
  const clientSecret = Deno.env.get("NAVER_SEARCH_CLIENT_SECRET");
  const mapNcpKeyId = Deno.env.get("NAVER_MAP_NCP_KEY_ID");
  const mapNcpKey = Deno.env.get("NAVER_MAP_NCP_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!clientId || !clientSecret || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse(503, { error: "Search service unavailable" });
  }

  try {
    const budget = new SearchBudget(supabaseUrl, serviceRoleKey, await searchActorKey(request, serviceRoleKey));
    await budget.reserve("request");
    const results = await searchPlaces(
      input,
      async (query) => {
        await budget.reserve("naver_local");
        const response = await fetch(naverSearchUrl(query), {
          headers: {
            "X-Naver-Client-Id": clientId,
            "X-Naver-Client-Secret": clientSecret,
          },
          signal: AbortSignal.timeout(5_000),
          redirect: "error",
        });
        if (!response.ok) throw new Error("Naver place search failed");
        return await response.json();
      },
      async (query, center) => {
        if (!mapNcpKeyId || !mapNcpKey) {
          throw new Error("Naver geocoding unavailable");
        }
        await budget.reserve("naver_geocoding");
        const response = await fetch(naverGeocodingUrl(query, center), {
          headers: {
            "x-ncp-apigw-api-key-id": mapNcpKeyId,
            "x-ncp-apigw-api-key": mapNcpKey,
            "Accept": "application/json",
          },
          signal: AbortSignal.timeout(5_000),
          redirect: "error",
        });
        if (!response.ok) throw new Error("Naver geocoding failed");
        return await response.json();
      },
      () => loadVisibleShops(supabaseUrl, serviceRoleKey),
    );
    return jsonResponse(200, { results });
  } catch (error) {
    if (error instanceof SearchBudgetError) {
      return new Response(JSON.stringify({ error: "Search temporarily limited", code: error.code, retry_after_seconds: error.retryAfterSeconds, limit_window: error.limitWindow }), {
        status: error.status,
        headers: { ...JSON_HEADERS, "Retry-After": error.retryAfterSeconds.toString(), "Cache-Control": "no-store" },
      });
    }
    return jsonResponse(502, { error: "Place search failed" });
  }
});

async function readSearchBody(request: Request): Promise<{ body: unknown; tooLarge: boolean }> {
  const limit = 4096;
  if (Number(request.headers.get("content-length")) > limit) return { body: null, tooLarge: true };
  if (!request.body) return { body: null, tooLarge: false };
  const reader = request.body.getReader();
  const bytes = new Uint8Array(limit);
  let size = 0;
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    void reader.cancel().catch(() => {});
  }, 3000);
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (size + value.length > limit) {
        await reader.cancel();
        return { body: null, tooLarge: true };
      }
      bytes.set(value, size);
      size += value.length;
    }
    return { body: timedOut ? null : JSON.parse(new TextDecoder().decode(bytes.subarray(0, size))), tooLarge: false };
  } catch {
    return { body: null, tooLarge: false };
  } finally {
    clearTimeout(timer);
    reader.releaseLock();
  }
}

async function loadVisibleShops(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<RegisteredShop[]> {
  const url = new URL(`${supabaseUrl}/rest/v1/ramen_shops`);
  url.searchParams.set("select", "id,naver_place_url,name,address,lat,lng");
  url.searchParams.set("is_visible", "eq.true");
  const response = await fetch(url, {
    headers: {
      "apikey": serviceRoleKey,
      "Authorization": `Bearer ${serviceRoleKey}`,
      "Accept": "application/json",
    },
  });
  if (!response.ok) throw new Error("Shop lookup failed");
  const rows = await response.json();
  if (!Array.isArray(rows)) throw new Error("Invalid shop response");
  return rows.map(parseShop).filter((shop): shop is RegisteredShop => shop !== null);
}

function parseShop(value: unknown): RegisteredShop | null {
  if (!isRecord(value)) return null;
  const lat = Number(value.lat);
  const lng = Number(value.lng);
  if (
    typeof value.id !== "string" ||
    typeof value.name !== "string" ||
    typeof value.address !== "string" ||
    !Number.isFinite(lat) ||
    !Number.isFinite(lng)
  ) {
    return null;
  }
  return {
    id: value.id,
    naverPlaceId: extractNaverPlaceId(value.naver_place_url),
    name: value.name,
    address: value.address,
    lat,
    lng,
  };
}

function naverSearchUrl(query: string): URL {
  const url = new URL(NAVER_LOCAL_SEARCH_URL);
  url.searchParams.set("query", query);
  url.searchParams.set("display", MAX_RESULTS.toString());
  url.searchParams.set("start", "1");
  return url;
}

function naverGeocodingUrl(
  query: string,
  center: { lat: number; lng: number },
): URL {
  const url = new URL(NAVER_GEOCODING_URL);
  url.searchParams.set("query", query);
  url.searchParams.set("coordinate", `${center.lng},${center.lat}`);
  url.searchParams.set("count", "10");
  return url;
}

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
