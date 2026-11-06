import {
  assertKnownEventType,
  createServiceClient,
  NotificationType,
  sendEventNotifications,
  ShopEvent,
} from "../_shared/event-notifications.ts";

type RequestPayload = { notification_type: "day_before" | "event_day" };

Deno.serve(async (request) => {
  const cronSecret = Deno.env.get("EVENT_NOTIFICATION_CRON_SECRET");
  if (!cronSecret) return new Response("Service unavailable", { status: 503 });
  if (request.headers.get("x-cron-secret") !== cronSecret) {
    return new Response("Unauthorized", { status: 401 });
  }

  try {
    const { notification_type: notificationType } = await request.json() as RequestPayload;
    if (notificationType !== "day_before" && notificationType !== "event_day") {
      return new Response("Invalid notification_type", { status: 400 });
    }

    const supabase = createServiceClient();
    const targetDate = seoulDate(notificationType);
    const { data: events, error } = await supabase
      .from("shop_events")
      .select("id,shop_id,title,event_type,start_date")
      .eq("start_date", targetDate);
    if (error) throw error;

    const results = [];
    for (const event of (events ?? []) as ShopEvent[]) {
      assertKnownEventType(event.event_type);
      results.push({
        event_id: event.id,
        ...(await sendEventNotifications(supabase, event, notificationType as NotificationType)),
      });
    }

    if (notificationType === "event_day" && (events?.length ?? 0) > 0) {
      const { error: cleanupError } = await supabase
        .from("user_event_notification_overrides")
        .delete()
        .in("event_id", events!.map(({ id }) => id));
      if (cleanupError) throw cleanupError;
    }
    return Response.json({ notification_type: notificationType, target_date: targetDate, events: results });
  } catch (error) {
    console.error(error);
    return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
});

function seoulDate(notificationType: "day_before" | "event_day") {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const get = (type: string) => Number(parts.find((part) => part.type === type)!.value);
  const utcDate = new Date(Date.UTC(get("year"), get("month") - 1, get("day")));
  if (notificationType === "day_before") utcDate.setUTCDate(utcDate.getUTCDate() + 1);
  return utcDate.toISOString().slice(0, 10);
}
