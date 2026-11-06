import { mediaStorage } from "../_shared/media-storage.ts";
import { validCalendarDate, validClosureSchedules } from "../_shared/operating-notice-schedule.ts";
import { isAdministrator } from "../_shared/admin-auth.ts";
import { assertKnownEventType, createServiceClient } from "../_shared/event-notifications.ts";
import { normalizeMapUrl } from "../_shared/event-venue-url.ts";
import { requiresExistingVenueSelection } from "../_shared/external-venue.ts";

const EVIDENCE_BUCKET = "news-report-evidence";
const EVENT_BUCKET = "event-images";
type Participant = { name: string; instagramUrl: string | null };

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ code: "method_not_allowed" }, 405);
  if (!await isAdministrator(request)) return json({ code: "administrator_required" }, 403);

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  const registrationType = text(body?.registration_type) ?? "event";
  if (registrationType !== "event" && registrationType !== "operating_notice") {
    return json({ code: "invalid_registration_type" }, 400);
  }
  const supabase = createServiceClient();
  if (registrationType === "operating_notice") return registerOperatingNotice(supabase, body ?? {});

  const shopName = text(body?.shop_name);
  const title = text(body?.title);
  const eventType = text(body?.event_type) ?? "limited_menu";
  const startDate = text(body?.start_date);
  const requestedEndDate = text(body?.end_date) ?? startDate;
  const description = text(body?.description);
  const participants = parseParticipants(body?.participants);
  let venueName = text(body?.venue_name);
  let venueAddress = text(body?.venue_address);
  const requestedExternalVenueId = text(body?.external_venue_id);
  let venueInstagramUrl = normalizeInstagramProfileUrl(body?.venue_instagram_url);
  let venueNaverMapUrl = normalizeMapUrl(body?.venue_naver_map_url, "naver");
  let venueKakaoMapUrl = normalizeMapUrl(body?.venue_kakao_map_url, "kakao");
  const sourceUrl = normalizeInstagramUrl(text(body?.source_url));
  const evidencePath = text(body?.evidence_path);
  const imageOnly = body?.image_only === true;
  if (!shopName || !title || !validCalendarDate(startDate) || !validCalendarDate(requestedEndDate) || requestedEndDate < startDate) {
    return json({ code: "invalid_draft" }, 400);
  }
  if (imageOnly ? !isEvidencePath(evidencePath) : !description || !sourceUrl || !isInstagramUrl(sourceUrl)) {
    return json({ code: "invalid_draft" }, 400);
  }
  if (!participants) return json({ code: "invalid_draft" }, 400);
  if (body?.venue_instagram_url !== undefined && body?.venue_instagram_url !== null && !venueInstagramUrl) return json({ code: "invalid_draft" }, 400);
  if ((body?.venue_naver_map_url != null && !venueNaverMapUrl) || (body?.venue_kakao_map_url != null && !venueKakaoMapUrl)) return json({ code: "invalid_draft" }, 400);
  const eventDescription = description ?? "";
  const eventSourceUrl = sourceUrl ?? "";
  try {
    assertKnownEventType(eventType);
  } catch {
    return json({ code: "invalid_draft" }, 400);
  }
  const endDate = eventType === "new_menu" ? dateAfterDays(startDate, 6) : requestedEndDate;

  const { data: shops, error: shopError } = await supabase.from("ramen_shops").select("id").eq("name", shopName).limit(2);
  if (shopError) return json({ code: "server_unavailable" }, 503);
  if (!shops || shops.length !== 1) return json({ code: "shop_not_resolved" }, 422);
  const shopId = shops[0].id as string;

  let externalVenueId = requestedExternalVenueId;
  let createdExternalVenueId: string | null = null;
  if (externalVenueId) {
    const { data: externalVenue, error: externalVenueError } = await supabase
      .from("external_venues")
      .select("id,name,address,instagram_url,naver_map_url,kakao_map_url")
      .eq("id", externalVenueId)
      .maybeSingle();
    if (externalVenueError || !externalVenue) return json({ code: "external_venue_not_found" }, 422);
    venueName = externalVenue.name as string;
    venueAddress = externalVenue.address as string | null;
    venueInstagramUrl = externalVenue.instagram_url as string | null;
    venueNaverMapUrl = externalVenue.naver_map_url as string | null;
    venueKakaoMapUrl = externalVenue.kakao_map_url as string | null;
  }
  if (venueName && !externalVenueId) {
    const { data: sameNameVenues, error: sameNameError } = await supabase
      .from("external_venues")
      .select("address,naver_map_url,kakao_map_url")
      .eq("name", venueName)
      .limit(100);
    if (sameNameError) return json({ code: "server_unavailable" }, 503);
    if (requiresExistingVenueSelection(sameNameVenues ?? [], venueAddress, venueNaverMapUrl, venueKakaoMapUrl)) {
      return json({ code: "external_venue_selection_required" }, 422);
    }
    const mapVenueQueries = [
      venueNaverMapUrl
        ? supabase.from("external_venues").select("id").eq("naver_map_url", venueNaverMapUrl).limit(1)
        : null,
      venueKakaoMapUrl
        ? supabase.from("external_venues").select("id").eq("kakao_map_url", venueKakaoMapUrl).limit(1)
        : null,
    ].filter((query): query is NonNullable<typeof query> => query !== null);
    const mapVenueResults = await Promise.all(mapVenueQueries);
    if (mapVenueResults.some(({ error }) => error)) return json({ code: "server_unavailable" }, 503);
    if (mapVenueResults.some(({ data }) => data && data.length > 0)) {
      return json({ code: "external_venue_selection_required" }, 422);
    }
    const { data: externalVenue, error: externalVenueError } = await supabase
      .from("external_venues")
      .insert({
        name: venueName,
        address: venueAddress,
        instagram_url: venueInstagramUrl,
        naver_map_url: venueNaverMapUrl,
        kakao_map_url: venueKakaoMapUrl,
      })
      .select("id")
      .single();
    if (externalVenueError?.code === "23505") return json({ code: "external_venue_selection_required" }, 422);
    if (externalVenueError || !externalVenue) return json({ code: "server_unavailable" }, 503);
    externalVenueId = externalVenue.id as string;
    createdExternalVenueId = externalVenueId;
  }
  if (externalVenueId && !venueName) return json({ code: "invalid_draft" }, 400);
  const eventParticipants = participants.filter((participant) =>
    !venueName || (
      participant.name.toLowerCase() !== venueName.toLowerCase() &&
      (!venueInstagramUrl || participant.instagramUrl !== venueInstagramUrl)
    )
  );

  const duplicateQuery = supabase
    .from("shop_events")
    .select("id")
    .eq("source_url", eventSourceUrl)
    .eq("title", title)
    .eq("start_date", startDate);
  const { data: duplicates, error: duplicateError } = externalVenueId
    ? await duplicateQuery.is("shop_id", null).eq("external_venue_id", externalVenueId).limit(1)
    : await duplicateQuery.eq("shop_id", shopId).limit(1);
  if (duplicateError) {
    if (createdExternalVenueId) await supabase.from("external_venues").delete().eq("id", createdExternalVenueId);
    return json({ code: "server_unavailable" }, 503);
  }
  if (duplicates && duplicates.length > 0) {
    if (createdExternalVenueId) await supabase.from("external_venues").delete().eq("id", createdExternalVenueId);
    await deleteEvidence(supabase, evidencePath);
    return json({ code: "duplicate" }, 409);
  }

  const eventId = crypto.randomUUID();
  let imagePath: string | null = null;
  let eventCreated = false;
  try {
    if (evidencePath && /^[\w-]+\.(?:jpe?g|png)$/i.test(evidencePath)) {
      imagePath = `events/${eventId}/1.${evidencePath.split(".").pop()!.toLowerCase()}`;
      await mediaStorage(supabase).copy(EVIDENCE_BUCKET, evidencePath, EVENT_BUCKET, imagePath);
    } else if (sourceUrl && /\/(?:p|reel)\//.test(sourceUrl)) {
      imagePath = await copyInstagramImage(supabase, sourceUrl, eventId);
    }

    const { error: insertError } = await supabase.from("shop_events").insert({
      id: eventId,
      shop_id: venueName ? null : shopId,
      external_venue_id: externalVenueId,
      venue_name: venueName,
      venue_instagram_url: venueName ? venueInstagramUrl : null,
      venue_naver_map_url: venueName ? venueNaverMapUrl : null,
      venue_kakao_map_url: venueName ? venueKakaoMapUrl : null,
      title,
      description: eventDescription,
      start_date: startDate,
      end_date: eventType === "store_renewal" ? null : endDate,
      source_url: eventSourceUrl,
      event_type: eventType,
      image_paths: imagePath ? [imagePath] : [],
      cancelled_dates: [],
      sold_out_dates: [],
    });
    if (insertError) throw insertError;
    eventCreated = true;
    await saveParticipants(supabase, eventId, venueName ? null : shopId, eventParticipants, venueName ? shopId : null);
    await deleteEvidence(supabase, evidencePath);
    return json({ id: eventId });
  } catch (error) {
    if (eventCreated) {
      await supabase.from("shop_event_participants").delete().eq("event_id", eventId);
      await supabase.from("shop_events").delete().eq("id", eventId);
    }
    if (createdExternalVenueId) await supabase.from("external_venues").delete().eq("id", createdExternalVenueId);
    if (imagePath) await mediaStorage(supabase).from(EVENT_BUCKET).remove([imagePath]);
    await deleteEvidence(supabase, evidencePath);
    console.error("register-event failed", error);
    return json({ code: "registration_failed" }, 422);
  }
});

async function deleteEvidence(supabase: ReturnType<typeof createServiceClient>, path: string | null) {
  if (isEvidencePath(path)) await mediaStorage(supabase).from(EVIDENCE_BUCKET).remove([path]);
}

async function copyInstagramImage(
  supabase: ReturnType<typeof createServiceClient>,
  sourceUrl: string,
  eventId: string,
): Promise<string | null> {
  const post = await fetch(sourceUrl, { headers: { "User-Agent": "Mozilla/5.0" } }).catch(() => null);
  if (!post?.ok) return null;
  const imageUrl = extractOpenGraphImageUrl(await post.text());
  if (!imageUrl) return null;

  const image = await fetch(imageUrl).catch(() => null);
  const contentType = image?.headers.get("content-type")?.split(";", 1)[0]?.toLowerCase() ?? "";
  const extension = contentType === "image/jpeg" ? "jpg" : contentType === "image/png" ? "png" : null;
  if (!image?.ok || !extension) return null;

  const imagePath = `events/${eventId}/1.${extension}`;
  const { error } = await mediaStorage(supabase).from(EVENT_BUCKET).upload(imagePath, await image.arrayBuffer(), {
    contentType,
    upsert: false,
  });
  if (error) throw error;
  return imagePath;
}

function extractOpenGraphImageUrl(html: string): string | null {
  const tag = html.match(/<meta\b[^>]*\bproperty=["']og:image["'][^>]*>/i)?.[0];
  const value = tag?.match(/\bcontent=["']([^"']+)["']/i)?.[1];
  if (!value) return null;
  try {
    const url = new URL(value.replaceAll("&amp;", "&"));
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function parseParticipants(value: unknown): Participant[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value)) return null;
  const participants: Participant[] = [];
  const names = new Set<string>();
  const instagramUrls = new Set<string>();
  for (const item of value) {
    if (!item || typeof item !== "object" || Array.isArray(item)) return null;
    const name = text((item as Record<string, unknown>).name);
    const instagramUrl = normalizeInstagramProfileUrl((item as Record<string, unknown>).instagram_url);
    if (!name || ((item as Record<string, unknown>).instagram_url !== null && !instagramUrl)) return null;
    const nameKey = name.toLowerCase();
    if (names.has(nameKey) || (instagramUrl && instagramUrls.has(instagramUrl))) continue;
    names.add(nameKey);
    if (instagramUrl) instagramUrls.add(instagramUrl);
    participants.push({ name, instagramUrl });
  }
  return participants;
}

async function saveParticipants(
  supabase: ReturnType<typeof createServiceClient>,
  eventId: string,
  hostShopId: string | null,
  participants: Participant[],
  requiredShopId: string | null,
) {
  const rows = [];
  const shopIds = new Set<string>();
  for (const participant of participants) {
    const shopId = await resolveParticipantShop(supabase, participant);
    if (shopId === hostShopId || (shopId && shopIds.has(shopId))) continue;
    if (shopId) shopIds.add(shopId);
    rows.push(shopId
      ? { event_id: eventId, shop_id: shopId, external_name: null, external_instagram_url: null }
      : { event_id: eventId, shop_id: null, external_name: participant.name, external_instagram_url: participant.instagramUrl });
  }
  if (requiredShopId && !shopIds.has(requiredShopId)) rows.push({ event_id: eventId, shop_id: requiredShopId, external_name: null, external_instagram_url: null });
  if (rows.length === 0) return;
  const { error } = await supabase.from("shop_event_participants").insert(rows);
  if (error) throw error;
}

async function resolveParticipantShop(supabase: ReturnType<typeof createServiceClient>, participant: Participant) {
  if (participant.instagramUrl) {
    const handle = extractInstagramUsername(participant.instagramUrl);
    const urls = handle ? [
      `https://www.instagram.com/${handle}`,
      `https://www.instagram.com/${handle}/`,
      `https://instagram.com/${handle}`,
      `https://instagram.com/${handle}/`,
    ] : [];
    const { data, error } = await supabase.from("ramen_shops").select("id").in("instagram_url", urls).limit(2);
    if (error) throw error;
    if (data?.length === 1) return data[0].id as string;
  }
  const { data, error } = await supabase.from("ramen_shops").select("id").eq("name", participant.name).limit(2);
  if (error) throw error;
  return data?.length === 1 ? data[0].id as string : null;
}

async function registerOperatingNotice(
  supabase: ReturnType<typeof createServiceClient>,
  body: Record<string, unknown>,
) {
  const shopName = text(body.shop_name);
  const noticeType = text(body.notice_type);
  const startDate = text(body.start_date);
  const endDate = text(body.end_date);
  const startTime = text(body.start_time);
  const endTime = text(body.end_time);
  const scheduleOverride = body.schedule_override;
  const dailySchedules = body.daily_schedules ?? [];
  const isMonthly = Array.isArray(dailySchedules) && dailySchedules.length > 0;
  const description = text(body.description);
  const sourceUrl = normalizeInstagramUrl(text(body.source_url));
  const evidencePath = text(body.evidence_path);
  if (
    !shopName || !isSupportedNoticeType(noticeType) || !startDate || !description || !sourceUrl ||
    !validCalendarDate(startDate) || !validCalendarDate(endDate) || endDate < startDate || (startTime && !validTime(startTime)) ||
    (endTime && !validTime(endTime)) || !isInstagramUrl(sourceUrl) ||
    (isMonthly && (noticeType !== "full_close" || scheduleOverride != null || startTime != null || endTime != null || !validClosureSchedules(dailySchedules, startDate, endDate))) ||
    (!Array.isArray(dailySchedules)) ||
    (scheduleOverride != null || startTime != null) ||
    (noticeType === "full_close" && endTime != null) ||
    ((noticeType === "early_close" || noticeType === "planned_close") && (!endTime || isMonthly))
  ) return json({ code: "invalid_operating_notice_draft" }, 400);

  const closureDates = isMonthly ? (dailySchedules as Array<{ date: string; closed: boolean }>).filter((day) => day.closed).map((day) => day.date) : [];

  const { data: shops, error: shopError } = await supabase.from("ramen_shops").select("id,instagram_url").eq("name", shopName).limit(2);
  if (shopError) return json({ code: "server_unavailable" }, 503);
  if (!shops || shops.length !== 1) return json({ code: "shop_not_resolved" }, 422);
  const shop = shops[0] as { id: string; instagram_url?: string | null };

  const duplicateNoticeQuery = supabase
    .from("admin_shop_operating_notice_records")
    .select("id")
    .eq("shop_id", shop.id)
    .eq("source_url", sourceUrl)
    .eq("notice_type", noticeType);
  const { data: duplicates, error: duplicateError } = await (isMonthly
    ? duplicateNoticeQuery.in("notice_date", closureDates)
    : duplicateNoticeQuery.eq("notice_date", startDate)).limit(1);
  if (duplicateError) return json({ code: "server_unavailable" }, 503);
  if (duplicates && duplicates.length > 0) {
    await deleteEvidence(supabase, evidencePath);
    return json({ code: "duplicate" }, 409);
  }


  try {
    const rawPostId = await ensureRawPost(supabase, shop.id, shop.instagram_url, sourceUrl, description);
    const baseNotice = {
      shop_id: shop.id, raw_post_id: rawPostId, notice_type: noticeType, description,
      notice_date: startDate, end_date: endDate, start_time: null, end_time: endTime,
      schedule_override: null, daily_schedules: [], source_url: sourceUrl,
      review_note: "관리자 미리보기 승인 등록",
    };
    // Store calendar closures as individual days so older app versions do not close the whole month.
    const rows = isMonthly ? closureDates.map((date) => ({ ...baseNotice, notice_date: date, end_date: date })) : [baseNotice];
    const { data: notices, error: insertError } = await supabase.from("admin_shop_operating_notice_records").insert(rows).select("id");
    if (insertError || !notices?.length) throw insertError ?? new Error("Operating notice was not created");
    await deleteEvidence(supabase, evidencePath);
    return json({ id: notices[0].id, ids: notices.map((notice: { id: string }) => notice.id) });
  } catch (error) {
    console.error("register-operating-notice failed", error);
    return json({ code: "registration_failed" }, 422);
  }
}

async function ensureRawPost(
  supabase: ReturnType<typeof createServiceClient>,
  shopId: string,
  instagramUrl: string | null | undefined,
  sourceUrl: string,
  description: string,
) {
  const { data: existing, error: existingError } = await supabase
    .from("instagram_posts_raw")
    .select("id")
    .eq("source_url", sourceUrl)
    .maybeSingle();
  if (existingError) throw existingError;
  if (existing) return existing.id as string;

  const { data: inserted, error } = await supabase
    .from("instagram_posts_raw")
    .insert({
      shop_id: shopId,
      instagram_username: extractInstagramUsername(instagramUrl) ?? "ramap_admin",
      source_type: sourceUrl.includes("/reel/") ? "reel" : "post",
      source_url: sourceUrl,
      source_key: sourceUrl,
      caption: description,
      raw_payload: { source: "admin_manual_registration" },
    })
    .select("id")
    .single();
  if (error || !inserted) throw error ?? new Error("Raw Instagram post was not created");
  return inserted.id as string;
}

function isInstagramUrl(value: string) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && (url.hostname === "instagram.com" || url.hostname.endsWith(".instagram.com"));
  } catch {
    return false;
  }
}
function isEvidencePath(value: string | null): value is string { return value !== null && /^[\w-]+\.(?:jpe?g|png)$/i.test(value); }
function dateAfterDays(value: string, days: number) {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}
function validTime(value: string | null) { return typeof value === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(value); }
function isSupportedNoticeType(value: string | null) { return value === "full_close" || value === "early_close" || value === "planned_close"; }
function text(value: unknown): string | null { return typeof value === "string" && value.trim() !== "" ? value.trim() : null; }
function normalizeInstagramUrl(value: string | null) {
  if (!value) return null;
  const match = value.match(/https?:\/\/(?:www\.)?instagram\.com\/(p|reel)\/([^/?#\s\]"']+)/i);
  if (match) return `https://www.instagram.com/${match[1].toLowerCase()}/${match[2]}/`;
  const profileMatch = value.match(/https?:\/\/(?:www\.)?instagram\.com\/([^/?#\s\]"']+)/i);
  if (!profileMatch || ["p", "reel"].includes(profileMatch[1].toLowerCase())) return null;
  return `https://www.instagram.com/${profileMatch[1]}/`;
}
function normalizeInstagramProfileUrl(value: unknown) {
  if (value === null) return null;
  if (typeof value !== "string") return null;
  const match = value.trim().match(/^https?:\/\/(?:www\.)?instagram\.com\/([^/?#\s\]"']+)\/?(?:[?#].*)?$/i);
  if (!match || ["p", "reel"].includes(match[1].toLowerCase())) return null;
  return `https://www.instagram.com/${match[1]}/`;
}
function extractInstagramUsername(value: string | null | undefined) {
  return value?.match(/instagram\.com\/([^/?#]+)/i)?.[1]?.toLowerCase() ?? null;
}
function json(body: Record<string, unknown>, status = 200): Response { return Response.json(body, { status }); }
