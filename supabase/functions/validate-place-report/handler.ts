import { parsePlaceUrl, PlaceReportError, verifyPlace } from "./place_link.ts";
import type { Fetcher } from "./place_link.ts";

type Configuration = { url: string; serviceKey: string; fetcher?: Fetcher; now?: () => number };
const MAX_BODY_BYTES = 8192;
const VALIDATION_TIMEOUT_MS = 5000;

export function createPlaceValidationHandler(configuration: Configuration) {
  const fetcher = configuration.fetcher ?? fetch;
  const now = configuration.now ?? Date.now;
  let cachedKey: { key: CryptoKey; expires: number } | null = null;
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json(405, { code: "method_not_allowed" }, { Allow: "POST" });
    const signal = AbortSignal.any([request.signal, AbortSignal.timeout(VALIDATION_TIMEOUT_MS)]);
    const started = Date.now();
    let phase = "authentication";
    try {
      const timestamp = request.headers.get("x-ramap-timestamp") ?? "";
      const signature = request.headers.get("x-ramap-signature") ?? "";
      if (!/^\d{10}$/.test(timestamp) || Math.abs(now() - Number(timestamp) * 1000) > 30_000 || !/^[a-f0-9]{64}$/.test(signature)) throw new PlaceReportError(401, "internal_authentication_required");
      const text = await readText(request, MAX_BODY_BYTES, 413, signal);
      if (!configuration.url || !configuration.serviceKey) throw new PlaceReportError(503, "place_validation_unavailable", 30);
      if (!cachedKey || cachedKey.expires < now()) {
        phase = "signing_key";
        const result = await rpc("read_place_report_validation_key", {}, configuration, fetcher, signal);
        if (typeof result.key !== "string" || !/^[a-f0-9]{64}$/.test(result.key)) throw new PlaceReportError(503, "place_validation_unavailable", 30);
        const key = await crypto.subtle.importKey("raw", fromHex(result.key), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
        cachedKey = { key, expires: now() + 60_000 };
      }
      if (!await crypto.subtle.verify("HMAC", cachedKey.key, fromHex(signature), new TextEncoder().encode(timestamp + "\n" + text))) throw new PlaceReportError(401, "internal_authentication_required");
      const body = parseBody(text);
      const input = parsePlaceUrl(body.place_url);
      phase = "reservation";
      const reservation = await rpc("reserve_place_report_validation", {
        p_actor_uid: body.actor_uid, p_actor_ip: body.actor_ip,
      }, configuration, fetcher, signal);
      if (reservation.allowed !== true) {
        if (reservation.allowed !== false || (reservation.status !== 429 && reservation.status !== 503) || typeof reservation.retry_after_seconds !== "number" || !Number.isInteger(reservation.retry_after_seconds) || reservation.retry_after_seconds < 1) throw new PlaceReportError(503, "place_validation_unavailable", 30);
        throw new PlaceReportError(reservation.status, reservation.status === 429 ? "REPORT_RATE_LIMITED" : "REPORT_SUBMISSION_UNAVAILABLE", reservation.retry_after_seconds);
      }
      phase = "provider";
      const place = await verifyPlace(input, fetcher, signal);
      if (signal.aborted) throw new PlaceReportError(503, "place_provider_unavailable", 30);
      return json(200, { provider: place.provider, place_id: place.id });
    } catch (error) {
      if (!(error instanceof PlaceReportError)) console.error("place validation unexpected failure", { kind: error instanceof Error ? error.name : typeof error });
      const failure = error instanceof PlaceReportError ? error : new PlaceReportError(503, "place_validation_unavailable", 30);
      if (failure.status === 503) console.warn("place validation unavailable", { phase, code: failure.code, elapsedMs: Date.now() - started, deadlineReached: signal.aborted });
      return json(failure.status, { code: failure.code }, failure.retryAfter ? { "Retry-After": String(failure.retryAfter) } : {});
    }
  };
}

function parseBody(text: string): Record<string, unknown> {
  let body: unknown;
  try { body = JSON.parse(text); } catch { throw new PlaceReportError(400, "invalid_request"); }
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new PlaceReportError(400, "invalid_request");
  const fields = body as Record<string, unknown>;
  if (Object.keys(fields).some((key) => !["place_url", "actor_uid", "actor_ip"].includes(key))) throw new PlaceReportError(400, "invalid_request");
  if (fields.actor_uid !== null && (typeof fields.actor_uid !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(fields.actor_uid))) throw new PlaceReportError(400, "invalid_request");
  if (typeof fields.actor_ip !== "string" || fields.actor_ip.length > 64 || (fields.actor_ip !== "shared-anonymous" && !/^[0-9a-fA-F.:]+$/.test(fields.actor_ip))) throw new PlaceReportError(400, "invalid_request");
  return fields;
}

async function rpc(name: string, body: Record<string, unknown>, configuration: Configuration, fetcher: Fetcher, signal: AbortSignal): Promise<Record<string, unknown>> {
  const response = await fetcher(`${configuration.url}/rest/v1/rpc/${name}`, {
    method: "POST", redirect: "error", signal,
    headers: { apikey: configuration.serviceKey, Authorization: `Bearer ${configuration.serviceKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  let payload: Record<string, unknown>;
  try { payload = JSON.parse(await readText(response, 16_384, 503, signal)); }
  catch { throw new PlaceReportError(503, "place_validation_unavailable", 30); }
  if (!payload || typeof payload !== "object" || Array.isArray(payload) || !response.ok) throw new PlaceReportError(503, "place_validation_unavailable", 30);
  return payload;
}

async function readText(source: Request | Response, limit: number, sizeStatus: number, signal: AbortSignal): Promise<string> {
  const reader = source.body?.getReader();
  if (!reader) throw new PlaceReportError(400, "invalid_request");
  let bytes = 0;
  const decoder = new TextDecoder();
  let text = "";
  const aborted = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", aborted, { once: true });
  try {
    while (true) {
      if (signal.aborted) throw new PlaceReportError(503, "place_validation_unavailable", 30);
      const { value, done } = await reader.read();
      if (signal.aborted) throw new PlaceReportError(503, "place_validation_unavailable", 30);
      if (done) break;
      bytes += value.byteLength;
      if (bytes > limit) throw new PlaceReportError(sizeStatus, "request_too_large");
      text += decoder.decode(value, { stream: true });
    }
    return text + decoder.decode();
  } finally {
    signal.removeEventListener("abort", aborted);
    void reader.cancel().catch(() => {});
  }
}

function fromHex(value: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(value.match(/../g)!, (byte) => parseInt(byte, 16));
}

function json(status: number, body: Record<string, unknown>, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store", ...headers } });
}
