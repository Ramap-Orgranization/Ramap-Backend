import { ImportationError, MAX_PLACES, matchPlaces, parseImportedPlaces, type ImportedPlace, type Shop } from "../kakao-importation/importation.ts"

const MAX_BODY_BYTES = 1_000_000
const AUTH_TIMEOUT_MS = 3_000

Deno.serve(async (request) => {
  if (request.method !== "POST") return response({ code: "method_not_allowed" }, 405, { Allow: "POST" })
  if (!await hasAuthenticatedUser(request)) return response({ code: "authentication_required" }, 401)
  const body = await request.json().catch(() => null) as { provider?: unknown; places?: unknown } | null
  if (body?.provider !== "naver") return response({ code: "unsupported_url" }, 400)
  try {
    const places = parseImportedPlaces(body.places)
    if (places.length === 0) throw new ImportationError("unavailable_list", "No public places")
    const matches = matchPlaces(places, await fetchVisibleShops())
    return response({ provider: body.provider, totalPlaceCount: places.length, matchedShopIds: matches.flatMap((item) => item.shopId === null ? [] : [item.shopId]), unmatchedPlaceNames: matches.filter((item) => item.shopId === null).map((item) => item.place.name) })
  } catch (error) {
    const code = error instanceof ImportationError ? error.code : "provider_failure"
    console.error("importation-match failed", { code, reason: error instanceof ImportationError ? error.message : error instanceof Error ? error.name : "unknown" })
    return response({ code }, code === "unsupported_url" ? 400 : 422)
  }
})

async function fetchVisibleShops(): Promise<Shop[]> {
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) throw new ImportationError("provider_failure", "Server database unavailable")
  const result = await fetch(`${url}/rest/v1/ramen_shops?select=id,kakao_place_url,name,address,lat,lng&is_visible=eq.true`, { headers: { apikey: key, Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(15_000) })
  if (!result.ok) throw new ImportationError("provider_failure", "Shop lookup failed")
  return await result.json() as Shop[]
}

async function hasAuthenticatedUser(request: Request): Promise<boolean> {
  const token = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim()
  const url = Deno.env.get("SUPABASE_URL"), anonKey = Deno.env.get("SUPABASE_ANON_KEY")
  if (!token || !url || !anonKey) return false
  try {
    const result = await fetch(`${url}/auth/v1/user`, { headers: { apikey: anonKey, Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(AUTH_TIMEOUT_MS) })
    if (!result.ok) return false
    const user = await result.json() as { id?: unknown }
    return typeof user.id === "string" && user.id.trim().length > 0
  } catch {
    return false
  }
}

function response(body: Record<string, unknown>, status = 200, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers })
}
