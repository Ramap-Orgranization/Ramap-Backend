import type { PushPayload } from "./notification-payload.ts";
import { buildPublicationPayload } from "./notification-payload.ts";
import type { PublicationFact } from "./notification-payload.ts";
import type { RpcClient } from "./notification-publication.ts";

export type PushTarget = { identifier: string; target_type: "fid" | "token" };
export type ProviderResult = { status: "sent" | "failed" | "unknown"; provider_id?: string; error?: string; invalidRegistration?: boolean };
export type PushProvider = { send(target: PushTarget, payload: PushPayload): Promise<ProviderResult> };
export type ClaimedDelivery = {
  delivery_id: string; claim_token: string; announcement_id: string; revision: number;
  registration_identifier: string; user_id: string; target_type: "fid" | "token";
  supported_protocol_version: number; facts: PublicationFact[]; source_url: string; kind: string;
};

export async function sendFcmPayload(projectId: string, accessToken: string, target: PushTarget, payload: PushPayload, request: typeof fetch = fetch, httpFailurePolicy: "conservative" | "legacy" = "conservative"): Promise<ProviderResult> {
  if (!/^[a-z][a-z0-9-]{4,62}$/.test(projectId) || !accessToken || !["fid", "token"].includes(target.target_type) || !target.identifier) throw new Error("invalid_push_configuration");
  try {
    const response = await request(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
      body: JSON.stringify({ message: {
        [target.target_type]: target.identifier, ...payload,
        android: { notification: { sound: "default" } },
        apns: {
          headers: { "apns-push-type": "alert", "apns-priority": "10" },
          payload: { aps: { alert: { title: payload.notification.title, body: payload.notification.body }, sound: "default" } },
        },
      } }), signal: AbortSignal.timeout(15_000),
    });
    if (response.ok) {
      const receipt = await response.json().catch(() => null) as { name?: string } | null;
      return { status: "sent", provider_id: receipt?.name };
    }
    const error = (await response.text()).slice(0, 2000);
    // New publications conservatively stop on uncertain HTTP responses. Legacy
    // events retain their existing failed-response retry policy; network
    // exceptions remain unknown for both paths.
    if (httpFailurePolicy === "conservative" && (response.status >= 500 || response.status === 408)) return { status: "unknown", error: `provider_${response.status}` };
    return { status: "failed", error: `provider_${response.status}`, invalidRegistration: /UNREGISTERED|registration-token-not-registered/i.test(error) };
  } catch { return { status: "unknown", error: "provider_response_unknown" }; }
}

export async function configuredPushProvider(env: (name: string) => string | undefined): Promise<PushProvider> {
  const raw = env("FIREBASE_SERVICE_ACCOUNT");
  if (!raw) throw new Error("push_transport_unconfigured");
  const account = JSON.parse(raw) as { client_email?: string; private_key?: string; project_id?: string };
  if (!account.client_email || !account.private_key || !account.project_id || !/^[a-z][a-z0-9-]{4,62}$/.test(account.project_id)) throw new Error("push_transport_unconfigured");
  const { JWT } = await import("npm:google-auth-library@10.2.1");
  const authorization = await new JWT({ email: account.client_email, key: account.private_key, scopes: ["https://www.googleapis.com/auth/firebase.messaging"] }).authorize();
  if (!authorization.access_token) throw new Error("push_transport_unconfigured");
  return { send: (target, payload) => sendFcmPayload(account.project_id!, authorization.access_token!, target, payload) };
}

export function publicationTransportEnabled(value: string | undefined): boolean { return value === "true"; }

export async function dispatchPublicationDeliveries(client: RpcClient, provider: PushProvider | (() => Promise<PushProvider>), enabled: boolean, limit = 20) {
  const totals = { claimed: 0, sent: 0, failed: 0, unknown: 0, skipped: 0 };
  if (!enabled) return { ...totals, disabled: true };
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error("invalid_batch_limit");
  const claims = await client.rpc("claim_notification_deliveries", { p_limit: limit, p_lease_seconds: 120 });
  if (claims.error) throw claims.error;
  const deliveries = (claims.data ?? []) as ClaimedDelivery[];
  if (!deliveries.length) return totals;
  // SQL's OFF gate returns no claims. Resolve credentials only after that gate,
  // but before prepare crosses the durable sending boundary.
  const sender = typeof provider === "function" ? await provider() : provider;
  for (const claim of deliveries) {
    totals.claimed++;
    // SQL rechecks consent, shop/type availability, ownership and protocol while
    // atomically changing claimed -> sending. Expired sending becomes unknown.
    const prepared = await client.rpc("prepare_notification_delivery", { p_delivery_id: claim.delivery_id, p_claim_token: claim.claim_token });
    if (prepared.error) { totals.skipped++; continue; }
    if (!prepared.data) { totals.skipped++; continue; }
    const delivery = prepared.data as ClaimedDelivery;
    let result: ProviderResult;
    let payload: PushPayload | null = null;
    try {
      payload = buildPublicationPayload({ notificationId: delivery.delivery_id, facts: delivery.facts,
        protocol: delivery.supported_protocol_version, sourceUrl: delivery.source_url,
        correction: delivery.kind !== "initial", cancelled: delivery.kind === "cancellation" });
    } catch { /* Invalid payload is a known failure before provider invocation. */ }
    try {
      result = payload ? await sender.send({ identifier: delivery.registration_identifier, target_type: delivery.target_type }, payload)
        : { status: "failed", error: "no_supported_selected_facts" };
    } catch { result = { status: "unknown", error: "delivery_result_unknown" }; }
    const completion = await Promise.resolve(client.rpc("complete_notification_delivery", {
      p_delivery_id: delivery.delivery_id, p_claim_token: claim.claim_token, p_status: result.status,
      p_provider_id: result.provider_id ?? null, p_error: result.error ?? null,
    })).catch(() => ({ data: false, error: true }));
    if (completion.error || completion.data !== true) {
      // Leave sending in place. Lease expiry converts it to unknown, not queued.
      totals.unknown++;
    } else totals[result.status]++;
  }
  return totals;
}
