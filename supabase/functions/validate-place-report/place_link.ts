export type Place = { provider: "naver" | "kakao"; id: string; pageUrl: string };
export type Fetcher = typeof fetch;

export class PlaceReportError extends Error {
  status: number;
  code: string;
  retryAfter: number | null;

  constructor(status: number, code: string, retryAfter: number | null = null) {
    super(code);
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

const INVALID = () => new PlaceReportError(400, "invalid_place_url");
const UNAVAILABLE = () => new PlaceReportError(503, "place_provider_unavailable", 30);
const ID = /^[1-9][0-9]{0,19}$/;
const SHORT_HOSTS = new Set(["naver.me", "kko.to"]);
const MAX_REDIRECTS = 3;
const MAX_HTML_BYTES = 131_072;
const PROVIDER_ATTEMPT_TIMEOUT_MS = 2000;
const MAX_PROVIDER_ATTEMPTS = 3;
const RETRYABLE_STATUSES = new Set([429, 500, 502, 503, 504]);

export function parsePlaceUrl(value: unknown): URL {
  if (typeof value !== "string" || value.length > 2048 || /[\s\x00-\x1f\x7f\\]/.test(value)) throw INVALID();
  const authority = value.match(/^https:\/\/([^/?#]+)/i)?.[1];
  if (!authority || /[@:]/.test(authority)) throw INVALID();
  let url: URL;
  try { url = new URL(value); } catch { throw INVALID(); }
  if (url.protocol !== "https:" || url.hash || url.username || url.password || url.port) throw INVALID();
  if (SHORT_HOSTS.has(url.hostname)) {
    const valid = url.hostname === "naver.me" ? /^\/[a-z0-9]{8}\/?$/i : /^\/[a-z0-9_-]{8,64}\/?$/i;
    if (!valid.test(url.pathname)) throw INVALID();
    return url;
  }
  placeFromUrl(url);
  return url;
}

export function placeFromUrl(url: URL): Place {
  const path = url.pathname;
  if (url.hostname === "place.map.kakao.com" && /^\/[1-9][0-9]{0,19}\/?$/.test(path)) return kakao(path.split("/")[1]);
  if (url.hostname === "map.kakao.com" && /^\/link\/map\/[1-9][0-9]{0,19}\/?$/.test(path)) return kakao(path.split("/")[3]);
  if (url.hostname === "applink.map.kakao.com" && /^\/(?:place)?$/.test(path)) return kakao(singleId(url, "id"));
  if (url.hostname === "map.naver.com") {
    const entry = path.match(/^\/(?:p\/|v5\/)?entry\/place\/([1-9][0-9]{0,19})\/?$/);
    if (entry) return naver(entry[1]);
    if (/^\/(?:p\/?|v5\/?)?$/.test(path)) return naver(singleId(url, "pinId"));
  }
  if (url.hostname === "m.place.naver.com") {
    const mobile = path.match(/^\/(restaurant|place|cafe|accommodation)\/([1-9][0-9]{0,19})(?:\/[a-z]+)?\/?$/);
    if (mobile) return naver(mobile[2], mobile[1]);
  }
  throw INVALID();
}

function singleId(url: URL, key: string): string {
  const values = url.searchParams.getAll(key);
  if (values.length !== 1 || !ID.test(values[0])) throw INVALID();
  return values[0];
}

function kakao(id: string): Place {
  if (!ID.test(id)) throw INVALID();
  return { provider: "kakao", id, pageUrl: `https://place.map.kakao.com/${id}` };
}

function naver(id: string, kind = "place"): Place {
  if (!ID.test(id)) throw INVALID();
  return { provider: "naver", id, pageUrl: `https://m.place.naver.com/${kind}/${id}/home` };
}

export async function verifyPlace(url: URL, fetcher: Fetcher, signal: AbortSignal): Promise<Place> {
  let current = url;
  let redirects = 0;
  while (SHORT_HOSTS.has(current.hostname)) {
    if (redirects++ >= MAX_REDIRECTS) throw INVALID();
    const response = await providerFetch(current.toString(), fetcher, signal);
    const location = response.headers.get("location");
    void response.body?.cancel().catch(() => {});
    if ([400, 404, 410].includes(response.status)) throw INVALID();
    if (![301, 302, 303, 307, 308].includes(response.status) || !location) throw UNAVAILABLE();
    try { current = parsePlaceUrl(new URL(location, current).toString()); } catch { throw INVALID(); }
  }
  const place = placeFromUrl(current);
  if (place.provider === "naver") return verifyNaverPlace(place, fetcher, signal);
  let pageUrl = place.pageUrl;
  for (let count = 0; count <= MAX_REDIRECTS; count++) {
    const response = await providerFetch(pageUrl, fetcher, signal);
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      void response.body?.cancel().catch(() => {});
      if (!location || count === MAX_REDIRECTS) throw UNAVAILABLE();
      const destination = parsePlaceUrl(new URL(location, pageUrl).toString());
      const target = placeFromUrl(destination);
      if (target.provider !== place.provider || target.id !== place.id) throw INVALID();
      pageUrl = destination.toString();
      continue;
    }
    if ([400, 404, 410].includes(response.status)) { void response.body?.cancel().catch(() => {}); throw INVALID(); }
    if (!response.ok || !response.headers.get("content-type")?.toLowerCase().includes("text/html")) {
      void response.body?.cancel().catch(() => {});
      throw UNAVAILABLE();
    }
    const html = await readProviderBody(response, signal, true);
    const metadata = readPlaceMetadata(html, place);
    if (!metadata) throw UNAVAILABLE();
    return place;
  }
  throw UNAVAILABLE();
}

async function verifyNaverPlace(place: Place, fetcher: Fetcher, signal: AbortSignal): Promise<Place> {
  // The map's ID-specific POI response distinguishes a live place from an empty result.
  const response = await providerFetch(`https://map.naver.com/p/api/place/directionsPOI/${place.id}`, fetcher, signal, true);
  if ([400, 404, 410].includes(response.status)) { void response.body?.cancel().catch(() => {}); throw INVALID(); }
  if (response.status !== 200 || !response.headers.get("content-type")?.toLowerCase().includes("application/json")) {
    console.warn("naver place lookup unavailable", { status: response.status, reason: "provider_response" });
    void response.body?.cancel().catch(() => {});
    throw UNAVAILABLE();
  }
  let result;
  try { result = JSON.parse(await readProviderBody(response, signal)); } catch {
    console.warn("naver place lookup unavailable", { reason: "invalid_json" });
    throw UNAVAILABLE();
  }
  const detail = result?.data?.placeDetail;
  if (!detail || typeof detail !== "object" || Array.isArray(detail)) throw UNAVAILABLE();
  if (detail.name === null && detail.address === null && detail.coordinate === null) throw INVALID();
  const address = detail.address?.roadAddress || detail.address?.address;
  const longitude = detail.coordinate?.longitude;
  const latitude = detail.coordinate?.latitude;
  if (typeof detail.name !== "string" || !detail.name.trim() || detail.name.length > 250
    || typeof address !== "string" || !address.trim()
    || typeof longitude !== "number" || !Number.isFinite(longitude) || longitude < -180 || longitude > 180
    || typeof latitude !== "number" || !Number.isFinite(latitude) || latitude < -90 || latitude > 90) throw UNAVAILABLE();
  return place;
}

async function providerFetch(url: string, fetcher: Fetcher, signal: AbortSignal, json = false): Promise<Response> {
  for (let attempt = 0; attempt < MAX_PROVIDER_ATTEMPTS; attempt++) {
    let response: Response;
    const started = Date.now();
    try {
      signal.throwIfAborted();
      response = await fetcher(url, {
        redirect: "manual",
        signal: AbortSignal.any([signal, AbortSignal.timeout(PROVIDER_ATTEMPT_TIMEOUT_MS)]),
        headers: json
          ? { Accept: "application/json", "User-Agent": "Mozilla/5.0", Referer: "https://map.naver.com/" }
          : { Accept: "text/html", "User-Agent": "Mozilla/5.0" },
      });
      console.info("place provider response", { host: new URL(url).hostname, status: response.status, elapsedMs: Date.now() - started });
    } catch {
      if (attempt === MAX_PROVIDER_ATTEMPTS - 1 || signal.aborted) throw UNAVAILABLE();
      console.info("place provider retry", { reason: "network" });
      await retryDelay(150 * (attempt + 1), signal);
      continue;
    }
    if (attempt === MAX_PROVIDER_ATTEMPTS - 1 || !RETRYABLE_STATUSES.has(response.status)) return response;
    const header = response.headers.get("retry-after");
    const delay = header === null ? 150 * (attempt + 1) : /^[0-9]+$/.test(header) ? Number(header) * 1000 : Date.parse(header) - Date.now();
    // Never retry before the provider's requested delay or beyond the request deadline.
    if (!Number.isFinite(delay) || delay > 1000) return response;
    void response.body?.cancel().catch(() => {});
    console.info("place provider retry", { status: response.status });
    await retryDelay(Math.max(0, delay), signal);
  }
  throw UNAVAILABLE();
}

async function retryDelay(milliseconds: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) throw UNAVAILABLE();
  await new Promise<void>((resolve, reject) => {
    const abort = () => {
      clearTimeout(timer);
      reject(UNAVAILABLE());
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, milliseconds);
    signal.addEventListener("abort", abort, { once: true });
  });
}

async function readProviderBody(response: Response, signal: AbortSignal, stopAtHead = false): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) throw UNAVAILABLE();
  const decoder = new TextDecoder();
  let html = "";
  let bytes = 0;
  const aborted = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", aborted, { once: true });
  try {
    while (bytes < MAX_HTML_BYTES) {
      signal.throwIfAborted();
      const { value, done } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      const chunk = value.subarray(0, MAX_HTML_BYTES - bytes);
      bytes += chunk.byteLength;
      html += decoder.decode(chunk, { stream: true });
      if (stopAtHead && /<\/head\s*>/i.test(html)) break;
    }
    return html + decoder.decode();
  } catch { throw UNAVAILABLE(); }
  finally {
    signal.removeEventListener("abort", aborted);
    void reader.cancel().catch(() => {});
  }
}

export function readPlaceMetadata(html: string, place: Place): boolean {
  const metadata = new Map<string, string>();
  for (const tag of html.matchAll(/<meta\b[^>]*>/gi)) {
    const attrs = new Map<string, string>();
    for (const match of tag[0].matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) attrs.set(match[1].toLowerCase(), decodeHtml(match[2] ?? match[3]));
    const key = attrs.get("property") ?? attrs.get("name");
    if (key && attrs.has("content")) metadata.set(key.toLowerCase(), attrs.get("content")!);
  }
  const title = metadata.get("og:title")?.trim();
  const description = metadata.get("og:description")?.trim();
  const canonical = metadata.get("og:url");
  if (!title || title.length > 250 || !description || !canonical || /^(네이버|네이버 지도|네이버 플레이스|카카오맵|Naver|Kakao Map)$/i.test(title) || /페이지를 찾을 수|접근이 제한|captcha|access denied/i.test(title)) return false;
  try {
    const target = placeFromUrl(parsePlaceUrl(canonical));
    return target.provider === place.provider && target.id === place.id;
  } catch { return false; }
}

function decodeHtml(value: string): string {
  return value.replace(/&(?:amp|quot|apos|lt|gt|#\d+|#x[0-9a-f]+);/gi, (entity) => {
    const named: Record<string, string> = { "&amp;": "&", "&quot;": '"', "&apos;": "'", "&lt;": "<", "&gt;": ">" };
    const known = named[entity.toLowerCase()];
    if (known) return known;
    const code = entity.toLowerCase().startsWith("&#x") ? parseInt(entity.slice(3, -1), 16) : Number(entity.slice(2, -1));
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : "";
  });
}
