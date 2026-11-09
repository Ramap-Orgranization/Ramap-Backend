import {
  assertKnownEventType,
  createServiceClient,
  sendEventNotifications,
  ShopEvent,
} from "../_shared/event-notifications.ts";

type WebhookPayload = { type: "INSERT"; table: "shop_events"; schema: "public"; record: ShopEvent };

Deno.serve(async (request) => {
  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret) {
    return new Response("Service unavailable", { status: 503 });
  }
  if (request.headers.get("x-webhook-secret") !== webhookSecret) {
    return new Response("Unauthorized", { status: 401 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return new Response("Invalid webhook payload", { status: 400 });
  }

  const payload = body as WebhookPayload;
  if (payload.schema !== "public" || payload.type !== "INSERT" || payload.table !== "shop_events") {
    return new Response("Ignored", { status: 202 });
  }
  if (!payload.record || typeof payload.record !== "object" || Array.isArray(payload.record)
    || typeof payload.record.event_type !== "string" || typeof payload.record.id !== "string"
    || !/^[0-9a-f-]{36}$/i.test(payload.record.id)) {
    return new Response("Invalid webhook payload", { status: 400 });
  }

  try {
    const supabase = createServiceClient();
    const { data: canonical, error } = await supabase.from("shop_events")
      .select("id,shop_id,title,event_type,start_date,announcement_id").eq("id", payload.record.id).maybeSingle();
    if (error) throw error;
    if (!canonical) return new Response("Event unavailable", { status: 202 });
    // A linked event belongs exclusively to the explicit publication path,
    // including draft revisions. Never trust the webhook row as canonical.
    if (canonical.announcement_id) return new Response("Publication owns delivery", { status: 202 });
    assertKnownEventType(canonical.event_type);
    return Response.json(await sendEventNotifications(supabase, canonical, "new_event"));
  } catch (error) {
    console.error(error);
    return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
});
