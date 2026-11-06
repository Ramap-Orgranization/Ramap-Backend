import { ImportationError, MAX_PLACES, matchPlaces, naverBookmarksUrl, parseKakaoBookmarks, parseKakaoFolderId, parseNaverBookmarks, parseNaverShareId, parseProviderUrl, providerForHost, kakaoBookmarksUrl, type ImportedPlace, type Provider, type Shop } from "./importation.ts"

const MAX_BODY_BYTES = 1_000_000
const PROVIDER_TIMEOUT_MS = 15_000
const AUTH_TIMEOUT_MS = 3_000
const MAX_REDIRECTS = 3

Deno.serve(async (request) => {
  if (request.method !== "POST") return response({ code: "method_not_allowed" }, 405, { Allow: "POST" })
  if (!await hasAuthenticatedUser(request)) return response({ code: "authentication_required" }, 401)
  const body = await request.json().catch(() => null) as { url?: unknown } | null
  if (typeof body?.url !== "string") return response({ code: "unsupported_url" }, 400)
  try {
    const finalUrl = await resolveUrl(body.url)
    const { provider } = parseProviderUrl(finalUrl.toString())
    if (provider !== "kakao") throw new ImportationError("unsupported_url", "Kakao URL required")
    const places = await fetchProviderPlaces(provider, finalUrl)
    if (places.length === 0) throw new ImportationError("unavailable_list", "No public places")
    const matches = matchPlaces(places.slice(0, MAX_PLACES), await fetchVisibleShops())
    return response({ provider, totalPlaceCount: places.length, matchedShopIds: matches.flatMap((item) => item.shopId === null ? [] : [item.shopId]), unmatchedPlaceNames: matches.filter((item) => item.shopId === null).map((item) => item.place.name) })
  } catch (error) {
    const code = error instanceof ImportationError ? error.code : "provider_failure"
    console.error("kakao-importation failed", { code, reason: error instanceof ImportationError ? error.message : error instanceof Error ? error.name : "unknown" })
    return response({ code }, code === "unsupported_url" ? 400 : 422)
  }
})

async function resolveUrl(value: string): Promise<URL> {
  let current = parseProviderUrl(value).url
  for (let count = 0; count < MAX_REDIRECTS; count += 1) {
    if (current.hostname !== "kko.to" && current.hostname !== "naver.me") return current
    let result = await fetchRedirect(current, "HEAD")
    if (result.status === 405) result = await fetchRedirect(current, "GET")
    const location = result.headers.get("location")
    if (location === null) throw new ImportationError("unavailable_list", "Short link has no destination")
    current = new URL(location, current)
    if (current.protocol !== "https:" || providerForHost(current.hostname) === null) throw new ImportationError("unsupported_url", "Redirect host is not allowed")
  }
  throw new ImportationError("unsupported_url", "Too many redirects")
}

async function fetchProviderPlaces(provider: Provider, finalUrl: URL): Promise<ImportedPlace[]> {
  const endpoint = provider === "kakao" ? kakaoBookmarksUrl(parseKakaoFolderId(finalUrl)) : naverBookmarksUrl(parseNaverShareId(finalUrl))
  const result = await fetchLimited(endpoint, provider, finalUrl)
  if (!result.headers.get("content-type")?.toLowerCase().includes("application/json")) throw new ImportationError("provider_failure", "Expected JSON")
  const payload = JSON.parse(new TextDecoder().decode(await readBody(result)))
  return provider === "kakao" ? parseKakaoBookmarks(payload) : parseNaverBookmarks(payload)
}

async function fetchLimited(url: URL, provider: Provider, finalUrl: URL): Promise<Response> {
  const headers: HeadersInit = provider === "kakao"
    ? { Accept: "application/json", Referer: finalUrl.toString(), "User-Agent": "Mozilla/5.0", "X-Requested-With": "XMLHttpRequest" }
    : { Accept: "application/json", Referer: `https://pages.map.naver.com/save-pages/pc/detail-list/${parseNaverShareId(finalUrl)}`, "User-Agent": "Mozilla/5.0", "Accept-Language": "ko" }
  const result = await fetch(url, { method: "GET", redirect: "manual", signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS), headers })
  if (!result.ok) throw new ImportationError("provider_failure", `Provider status ${result.status}`)
  if (Number(result.headers.get("content-length") ?? "0") > MAX_BODY_BYTES) throw new ImportationError("provider_failure", "Response too large")
  return result
}

async function fetchRedirect(url: URL, method: "GET" | "HEAD"): Promise<Response> {
  return await fetch(url, { method, redirect: "manual", signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) })
}

async function readBody(result: Response): Promise<Uint8Array> {
  const reader = result.body?.getReader(); if (reader === undefined) return new Uint8Array()
  const chunks: Uint8Array[] = []; let bytes = 0
  while (true) { const next = await reader.read(); if (next.done) break; bytes += next.value.byteLength; if (bytes > MAX_BODY_BYTES) { await reader.cancel(); throw new ImportationError("provider_failure", "Response too large") }; chunks.push(next.value) }
  const output = new Uint8Array(bytes); let offset = 0; for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.byteLength }; return output
}
async function fetchVisibleShops(): Promise<Shop[]> {
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) throw new ImportationError("provider_failure", "Server database unavailable")
  const result = await fetch(`${url}/rest/v1/ramen_shops?select=id,kakao_place_url,name,address,lat,lng&is_visible=eq.true`, { headers: { apikey: key, Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) })
  if (!result.ok) throw new ImportationError("provider_failure", "Shop lookup failed")
  return await result.json() as Shop[]
}
async function hasAuthenticatedUser(request: Request): Promise<boolean> {
  const token = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim()
  const url = Deno.env.get("SUPABASE_URL"), anonKey = Deno.env.get("SUPABASE_ANON_KEY")
  if (!token || !url || !anonKey) return false
  try {
    const result = await fetch(`${url}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(AUTH_TIMEOUT_MS),
    })
    if (!result.ok) return false
    const user = await result.json() as { id?: unknown }
    return typeof user.id === "string" && user.id.trim().length > 0
  } catch {
    return false
  }
}
function response(body: Record<string, unknown>, status = 200, headers: HeadersInit = {}): Response { return Response.json(body, { status, headers }) }
