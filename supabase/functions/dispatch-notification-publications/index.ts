import { createServiceClient } from "../_shared/event-notifications.ts";
import { configuredPushProvider, dispatchPublicationDeliveries, publicationTransportEnabled } from "../_shared/push-delivery.ts";
import { publishPendingOperatingNotices } from "../_shared/operating-notice-publication.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ code: "method_not_allowed" }, { status: 405 });
  const secret = Deno.env.get("NOTIFICATION_DISPATCH_SECRET");
  if (!secret) return Response.json({ code: "dispatcher_unconfigured" }, { status: 503 });
  if (request.headers.get("x-notification-dispatch-secret") !== secret) return Response.json({ code: "unauthorized" }, { status: 401 });
  const enabled = publicationTransportEnabled(Deno.env.get("NOTIFICATION_PUBLICATION_TRANSPORT_ENABLED"));
  if (!enabled) return Response.json({ disabled: true, sent: 0 });
  const body = await request.json().catch(() => null) as { limit?: unknown } | null;
  if (!body || !Number.isInteger(body.limit) || Number(body.limit) < 1 || Number(body.limit) > 100) return Response.json({ code: "invalid_batch_limit" }, { status: 400 });
  try {
    const provider = () => configuredPushProvider((name) => Deno.env.get(name));
    const client = createServiceClient();
    const notices = await publishPendingOperatingNotices(client, Number(body.limit));
    return Response.json({ ...await dispatchPublicationDeliveries(client, provider, enabled, Number(body.limit)), notices });
  } catch {
    return Response.json({ code: "dispatch_unavailable" }, { status: 503 });
  }
});
