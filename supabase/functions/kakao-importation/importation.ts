export type Provider = "kakao" | "naver"
export type ImportedPlace = { sourceId?: string; name: string; address?: string; lat?: number; lng?: number }
export type Shop = { id: string; kakao_place_url?: string | null; name: string; address: string; lat: number; lng: number }

export const MAX_PLACES = 100
export const PROVIDER_HOSTS: Record<Provider, Set<string>> = {
  kakao: new Set(["map.kakao.com", "kko.to"]),
  naver: new Set(["map.naver.com", "m.map.naver.com", "naver.me"]),
}
export const PROVIDER_API_HOSTS: Record<Provider, string> = {
  kakao: "map.kakao.com",
  naver: "pages.map.naver.com",
}

export class ImportationError extends Error {
  constructor(readonly code: "unsupported_url" | "provider_failure" | "unavailable_list", message: string) { super(message) }
}

export function parseProviderUrl(value: string): { provider: Provider; url: URL } {
  let url: URL
  try { url = new URL(value.trim()) } catch { throw new ImportationError("unsupported_url", "Invalid URL") }
  if (url.protocol !== "https:") throw new ImportationError("unsupported_url", "Only HTTPS URLs are supported")
  const provider = providerForHost(url.hostname)
  if (provider === null) throw new ImportationError("unsupported_url", "Unsupported map provider")
  return { provider, url }
}

export function providerForHost(host: string): Provider | null {
  if (PROVIDER_HOSTS.kakao.has(host)) return "kakao"
  if (PROVIDER_HOSTS.naver.has(host)) return "naver"
  return null
}

export function parseKakaoFolderId(url: URL): string {
  if (url.hostname !== "map.kakao.com") throw new ImportationError("unsupported_url", "Unexpected Kakao host")
  const folderId = url.searchParams.get("folderid") ?? parseKakaoSchemeFolderId(url.searchParams.get("kakaomapScheme"))
  if (folderId === null || !/^\d+$/.test(folderId)) throw new ImportationError("unavailable_list", "Kakao folder is unavailable")
  return folderId
}

function parseKakaoSchemeFolderId(scheme: string | null): string | null {
  if (scheme === null) return null
  try { return new URL(scheme, "https://map.kakao.com").searchParams.get("folderid") } catch { return null }
}

export function parseNaverShareId(url: URL): string {
  if (url.hostname !== "map.naver.com" && url.hostname !== "m.map.naver.com") throw new ImportationError("unsupported_url", "Unexpected Naver host")
  const match = url.pathname.match(/\/(?:sharedPlace|myPlace)\/folder\/([a-zA-Z0-9]+)/)
  if (match === null) throw new ImportationError("unavailable_list", "Naver shared folder is unavailable")
  return match[1]
}

export function kakaoBookmarksUrl(folderId: string): URL {
  return new URL(`/favorite/list?folderid=${encodeURIComponent(folderId)}`, "https://map.kakao.com")
}

export function naverBookmarksUrl(shareId: string): URL {
  return new URL(`/save-pages/api/maps-bookmark/v3/shares/${encodeURIComponent(shareId)}/bookmarks?start=0&limit=5000&sort=lastUseTime&createIdNo=false`, "https://pages.map.naver.com")
}

export function parseKakaoBookmarks(payload: unknown): ImportedPlace[] {
  const root = record(payload)
  const favorites = array(root?.favorites) ?? []
  return favorites.map(kakaoPlace).filter(isPlace).slice(0, MAX_PLACES)
}

export function parseNaverBookmarks(payload: unknown): ImportedPlace[] {
  const root = record(payload)
  const bookmarks = array(root?.bookmarkList) ?? []
  return bookmarks.map(naverPlace).filter(isPlace).slice(0, MAX_PLACES)
}

export function parseImportedPlaces(value: unknown): ImportedPlace[] {
  const places = array(value) ?? []
  return places.map(importedPlace).filter(isPlace).slice(0, MAX_PLACES)
}

export function matchPlaces(places: ImportedPlace[], shops: Shop[]): Array<{ place: ImportedPlace; shopId: string | null }> {
  return places.map((place) => ({ place, shopId: uniqueShopId(place, shops) }))
}

function kakaoPlace(value: unknown): ImportedPlace | null {
  const item = record(value); if (item === null) return null
  if (item.type !== "PLACE") return null
  return place(item.key, item.display1, item.display2, undefined, undefined)
}
function naverPlace(value: unknown): ImportedPlace | null {
  const item = record(value); if (item === null) return null
  if (item.type !== "place" || item.available === false || item.matched === false) return null
  return place(item.sid, item.name, item.address, item.py, item.px)
}
function importedPlace(value: unknown): ImportedPlace | null {
  const item = record(value); if (item === null) return null
  return place(item.sourceId, item.name, item.address, item.lat, item.lng)
}
function place(sourceId: unknown, name: unknown, address: unknown, lat: unknown, lng: unknown): ImportedPlace | null {
  if (typeof name !== "string" || name.trim() === "") return null
  return { sourceId: text(sourceId), name: name.trim(), address: text(address), lat: number(lat), lng: number(lng) }
}
function uniqueShopId(place: ImportedPlace, shops: Shop[]): string | null {
  const byId = place.sourceId === undefined ? [] : shops.filter((shop) => extractKakaoPlaceId(shop.kakao_place_url) === place.sourceId)
  if (byId.length === 1) return byId[0].id
  const address = place.address
  const byAddress = address === undefined ? [] : shops.filter((shop) => normalize(shop.address) === normalize(address))
  if (byAddress.length === 1) return byAddress[0].id
  const byName = shops.filter((shop) => normalize(shop.name) === normalize(place.name))
  const byNameNearby = nearbyShops(place, byName)
  if (byNameNearby.length === 1) return byNameNearby[0].id
  return nearestShopId(place, shops)
}
export function extractKakaoPlaceId(value: string | null | undefined): string | undefined {
  const match = value?.trim().match(/^https?:\/\/place\.map\.kakao\.com\/(\d+)(?:[/?#]|$)/i)
  return match?.[1]
}
function nearbyShops(place: ImportedPlace, shops: Shop[]): Shop[] {
  return place.lat === undefined || place.lng === undefined ? [] : shops.filter((shop) => meters(place.lat!, place.lng!, shop.lat, shop.lng) <= MAX_COORDINATE_DISTANCE_METERS)
}
function nearestShopId(place: ImportedPlace, shops: Shop[]): string | null {
  const nearby = nearbyShops(place, shops)
  if (nearby.length === 0) return null
  const ranked = nearby.map((shop) => ({ shop, distance: meters(place.lat!, place.lng!, shop.lat, shop.lng) })).sort((first, second) => first.distance - second.distance)
  const nearest = ranked[0]
  const secondNearest = ranked[1]
  if (secondNearest !== undefined && secondNearest.distance - nearest.distance < MIN_NEAREST_DISTANCE_MARGIN_METERS) return null
  return nearest.shop.id
}
function normalize(value: string): string { return value.replace(/\s|[-().,]/g, "").toLowerCase() }
function meters(a: number, b: number, c: number, d: number): number { const r = Math.PI / 180, x = (c-a)*r, y = (d-b)*r, q = Math.sin(x/2)**2 + Math.cos(a*r)*Math.cos(c*r)*Math.sin(y/2)**2; return 6371000*2*Math.atan2(Math.sqrt(q), Math.sqrt(1-q)) }
function record(value: unknown): Record<string, unknown> | null { return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null }
function array(value: unknown): unknown[] | null { return Array.isArray(value) ? value : null }
function text(value: unknown): string | undefined { return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined }
function number(value: unknown): number | undefined { const parsed = typeof value === "number" ? value : Number(value); return Number.isFinite(parsed) ? parsed : undefined }
function isPlace(value: ImportedPlace | null): value is ImportedPlace { return value !== null }

const MAX_COORDINATE_DISTANCE_METERS = 50
const MIN_NEAREST_DISTANCE_MARGIN_METERS = 20
