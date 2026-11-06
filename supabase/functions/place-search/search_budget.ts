export type BudgetKind = "request" | "naver_local" | "naver_geocoding";
export type BudgetWindow = "minute" | "hour" | "day";

export class SearchBudgetError extends Error {
  status: number;
  code: string;
  retryAfterSeconds: number;
  limitWindow: BudgetWindow | null;

  constructor(status: number, code: string, retryAfterSeconds: number, limitWindow: BudgetWindow | null = null) {
    super(code);
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
    this.limitWindow = limitWindow;
  }
}

type Denial = { status: number; code: string; retryAt: number; cacheUntil: number; limitWindow: BudgetWindow | null };
const denialCache = new Map<string, Denial>();
const CACHE_LIMIT = 256;
const CACHE_TTL_MS = 30_000;
const BUDGET_TIMEOUT_MS = 3_000;

export class SearchBudget {
  url: string;
  serviceKey: string;
  actorKey: string;

  constructor(url: string, serviceKey: string, actorKey: string) {
    this.url = url;
    this.serviceKey = serviceKey;
    this.actorKey = actorKey;
  }

  async reserve(kind: BudgetKind): Promise<void> {
    const namespace = `${this.url}:${kind}:`;
    for (const key of [namespace + "global", namespace + this.actorKey]) {
      const cached = denialCache.get(key);
      if (!cached) continue;
      if (cached.cacheUntil <= Date.now()) {
        denialCache.delete(key);
        continue;
      }
      throw new SearchBudgetError(cached.status, cached.code, Math.max(1, Math.ceil((cached.retryAt - Date.now()) / 1000)), cached.limitWindow);
    }
    try {
      const response = await fetch(`${this.url}/rest/v1/rpc/consume_place_search_budget`, {
        method: "POST",
        headers: { apikey: this.serviceKey, Authorization: `Bearer ${this.serviceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_kind: kind, p_actor_key: kind === "request" ? this.actorKey : null }),
        signal: AbortSignal.timeout(BUDGET_TIMEOUT_MS),
      });
      if (!response.ok) throw new Error("Budget unavailable");
      const result = await response.json();
      if (result?.allowed === true) return;
      if (result?.allowed !== false || !Number.isInteger(result.retry_after_seconds) || result.retry_after_seconds < 1 || !["global", "client"].includes(result.scope) || !["limit", "disabled"].includes(result.reason)) {
        throw new Error("Invalid budget response");
      }
      const status = result.reason === "limit" ? 429 : 503;
      const code = status === 429 ? "search_rate_limited" : "search_budget_unavailable";
      if (result.window != null && !["minute", "hour", "day"].includes(result.window)) throw new Error("Invalid budget window");
      const limitWindow: BudgetWindow | null = status === 429 ? result.window ?? null : null;
      const retryAt = Date.now() + result.retry_after_seconds * 1000;
      if (denialCache.size >= CACHE_LIMIT) denialCache.delete(denialCache.keys().next().value!);
      denialCache.set(namespace + (result.scope === "global" ? "global" : this.actorKey), { status, code, retryAt, cacheUntil: Math.min(retryAt, Date.now() + CACHE_TTL_MS), limitWindow });
      throw new SearchBudgetError(status, code, result.retry_after_seconds, limitWindow);
    } catch (error) {
      if (error instanceof SearchBudgetError) throw error;
      throw new SearchBudgetError(503, "search_budget_unavailable", 3);
    }
  }
}

export async function searchActorKey(request: Request, serviceKey: string): Promise<string> {
  // Proxy headers are a fairness hint, not an identity proof. The global limits
  // remain authoritative even if callers rotate or forge client addresses.
  const forwarded = request.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim();
  const candidate = forwarded || request.headers.get("x-real-ip")?.trim() || "shared-anonymous";
  const address = candidate.length <= 64 && /^[0-9a-fA-F.:]+$/.test(candidate) ? candidate.toLowerCase() : "shared-anonymous";
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(serviceKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode("ramap.place-search.ip:" + address));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
