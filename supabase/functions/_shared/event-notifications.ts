import { createClient } from "npm:@supabase/supabase-js@2.55.0";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.55.0";
import { JWT } from "npm:google-auth-library@10.2.1";

export type NotificationType = "new_event" | "day_before" | "event_day";
export type EventType = "collab" | "popup" | "limited_menu" | "summer_limited" | "new_menu" | "store_renewal";
export type ShopEvent = {
  id: string;
  shop_id: string | null;
  title: string;
  event_type: EventType;
  start_date?: string;
};
type ServiceAccount = { client_email: string; private_key: string; project_id: string };
type Registration = {
  identifier: string;
  target_type: "fid" | "token";
  user_id: string;
};

const TITLES: Record<EventType, Record<NotificationType, string>> = {
  collab: {
    new_event: "새 콜라보가 등록됐어요",
    day_before: "내일 콜라보가 시작돼요",
    event_day: "오늘 콜라보가 시작돼요",
  },
  popup: {
    new_event: "새 팝업이 등록됐어요",
    day_before: "내일 팝업이 시작돼요",
    event_day: "오늘 팝업이 시작돼요",
  },
  limited_menu: {
    new_event: "새 한정 메뉴가 등록됐어요",
    day_before: "내일 한정 메뉴가 시작돼요",
    event_day: "오늘 한정 메뉴가 시작돼요",
  },
  summer_limited: {
    new_event: "새 여름 한정 메뉴가 등록됐어요",
    day_before: "내일 여름 한정 메뉴가 시작돼요",
    event_day: "오늘 여름 한정 메뉴가 시작돼요",
  },
  new_menu: {
    new_event: "새 신메뉴가 등록됐어요",
    day_before: "내일 신메뉴가 출시돼요",
    event_day: "오늘 신메뉴가 출시돼요",
  },
  store_renewal: {
    new_event: "새 매장 리뉴얼이 등록됐어요",
    day_before: "내일 매장 리뉴얼이 시작돼요",
    event_day: "오늘 매장 리뉴얼이 시작돼요",
  },
};

export function createServiceClient() {
  return createClient(
    requiredEnv("SUPABASE_URL"),
    requiredEnv("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

export function assertKnownEventType(value: string): asserts value is EventType {
  if (!(value in TITLES)) throw new Error(`Unsupported event_type: ${value}`);
}

export function notificationTitle(eventType: EventType, notificationType: NotificationType) {
  return TITLES[eventType][notificationType];
}

export async function sendEventNotifications(
  supabase: SupabaseClient,
  event: ShopEvent,
  notificationType: NotificationType,
) {
  assertKnownEventType(event.event_type);
  const userIds = await resolveAudience(supabase, event, notificationType);
  if (userIds.length === 0) return { targeted: 0, sent: 0, failed: 0, unknown: 0 };

  const { data: registrations, error } = await supabase
    .from("push_registrations")
    .select("identifier,target_type,user_id")
    .in("user_id", userIds);
  if (error) throw error;

  const serviceAccount = JSON.parse(requiredEnv("FIREBASE_SERVICE_ACCOUNT")) as ServiceAccount;
  const accessToken = await new JWT({
    email: serviceAccount.client_email,
    key: serviceAccount.private_key,
    scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
  }).authorize().then(({ access_token }) => access_token);
  if (!accessToken) throw new Error("Failed to obtain Firebase access token");

  const totals = { targeted: registrations?.length ?? 0, sent: 0, failed: 0, unknown: 0 };
  for (const registration of (registrations ?? []) as Registration[]) {
    const { data: claimed, error: claimError } = await supabase.rpc(
      "claim_event_notification_delivery",
      {
        delivery_event_id: event.id,
        delivery_user_id: registration.user_id,
        delivery_registration_identifier: registration.identifier,
        delivery_notification_type: notificationType,
      },
    );
    if (claimError) throw claimError;
    if (!claimed) continue;

    try {
      const result = await sendMessage(
        serviceAccount.project_id,
        accessToken,
        registration,
        event,
        notificationType,
      );
      if (!result.ok) {
        await finishDelivery(supabase, event, registration, notificationType, "failed", result.error);
        totals.failed++;
        if (result.invalidRegistration) {
          await supabase.from("push_registrations").delete().eq("identifier", registration.identifier);
        }
      } else {
        await finishDelivery(supabase, event, registration, notificationType, "sent");
        totals.sent++;
      }
    } catch (error) {
      await finishDelivery(supabase, event, registration, notificationType, "unknown", errorMessage(error));
      totals.unknown++;
    }
  }
  return totals;
}

async function resolveAudience(
  supabase: SupabaseClient,
  event: ShopEvent,
  notificationType: NotificationType,
) {
  const { data: participants, error: participantError } = await supabase
    .from("shop_event_participants")
    .select("shop_id")
    .eq("event_id", event.id)
    .not("shop_id", "is", null);
  if (participantError) throw participantError;
  const shopIds = [...new Set([event.shop_id, ...(participants ?? []).map(({ shop_id }) => shop_id as string)].filter((shopId): shopId is string => shopId !== null))];
  if (shopIds.length === 0) return [];

  const { data: subscriptions, error: subscriptionError } = await supabase
    .from("shop_event_notification_subscriptions")
    .select("user_id")
    .in("shop_id", shopIds);
  if (subscriptionError) throw subscriptionError;
  const audience = new Set((subscriptions ?? []).map(({ user_id }) => user_id as string));

  if (notificationType !== "new_event") {
    const { data: overrides, error: overrideError } = await supabase
      .from("user_event_notification_overrides")
      .select("user_id,enabled")
      .eq("event_id", event.id);
    if (overrideError) throw overrideError;
    for (const override of overrides ?? []) {
      if (override.enabled) audience.add(override.user_id);
      else audience.delete(override.user_id);
    }
  }

  if (audience.size === 0) return [];
  const { data: disabled, error: preferenceError } = await supabase
    .from("user_event_notification_preferences")
    .select("user_id")
    .eq("enabled", false)
    .in("user_id", [...audience]);
  if (preferenceError) throw preferenceError;
  for (const preference of disabled ?? []) audience.delete(preference.user_id);
  return [...audience];
}

async function sendMessage(
  projectId: string,
  accessToken: string,
  registration: Registration,
  event: ShopEvent,
  notificationType: NotificationType,
) {
  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({
      message: {
        [registration.target_type]: registration.identifier,
        notification: { title: notificationTitle(event.event_type, notificationType), body: event.title },
        data: {
          notification_type: notificationType,
          event_type: event.event_type,
          event_id: event.id,
          shop_id: event.shop_id ?? "",
          deep_link: `ramap://notification/event?event_id=${encodeURIComponent(event.id)}`,
        },
        android: { notification: { sound: "default" } },
        apns: { payload: { aps: { sound: "default" } } },
      },
    }),
    signal: AbortSignal.timeout(15_000),
  });
  if (response.ok) return { ok: true as const };
  const error = await response.text();
  return {
    ok: false as const,
    error,
    invalidRegistration: /UNREGISTERED|registration-token-not-registered/i.test(error),
  };
}

async function finishDelivery(
  supabase: SupabaseClient,
  event: ShopEvent,
  registration: Registration,
  notificationType: NotificationType,
  status: "sent" | "failed" | "unknown",
  lastError?: string,
) {
  const { error } = await supabase.from("event_notification_deliveries").update({
    status,
    last_error: lastError?.slice(0, 2000) ?? null,
    updated_at: new Date().toISOString(),
    sent_at: status === "sent" ? new Date().toISOString() : null,
  }).match({
    event_id: event.id,
    user_id: registration.user_id,
    registration_identifier: registration.identifier,
    notification_type: notificationType,
  });
  if (error) throw error;
}

function requiredEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
