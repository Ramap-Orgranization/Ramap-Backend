import { mediaStorage } from "../_shared/media-storage.ts";
import { dailySchedulesSchema, validCalendarDate, validClosureSchedules, type DailySchedule } from "../_shared/operating-notice-schedule.ts";
import { isAdministrator } from "../_shared/admin-auth.ts";
import { createServiceClient } from "../_shared/event-notifications.ts";
import { normalizeMapUrl } from "../_shared/event-venue-url.ts";

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const EVIDENCE_BUCKET = "news-report-evidence";
const EVENT_EXTRACTION_PROMPT =
  "라멘 매장의 이벤트 등록 초안을 추출하세요. 입력에 없는 사실은 절대 만들지 마세요. " +
  "원문 캡션이 있으면 description은 캡션의 문구, 이모지, 구두점, 줄바꿈을 그대로 보존하세요. " +
  "캡션을 요약·번역·홍보 문구로 재작성하지 말고, 이미지에만 있는 내용은 캡션에 섞지 마세요. " +
  "이미지만 있으면 이미지에서 실제로 읽히는 내용만 사용하고 OCR이 불확실하면 uncertainties에 적으세요. " +
  "title은 원문에 명시된 이벤트명이나 메뉴명만 짧게 적고, 원문에 없으면 null로 반환하세요. " +
  "날짜는 YYYY-MM-DD로 변환하고, 상대 날짜는 게시일이나 관찰일을 알 수 없으면 추측하지 마세요. " +
  "명확한 하루 일정만 start_date와 end_date를 같은 날짜로 반환하세요. " +
  "store_renewal은 end_date를 null로 반환하세요. 그 외 날짜가 불명확하거나 누락되면 null과 한국어 uncertainties를 반환하세요. " +
  "event_type은 collab, popup, limited_menu, summer_limited, new_menu, store_renewal 중 하나를 반환하세요. 명시적으로 다른 매장·브랜드·셰프 등과 함께하는 콜라보 문맥일 때만 collab을 선택하세요. " +
  "participants에는 원문에서 이벤트 참여 또는 콜라보가 명시된 주체만 반환하세요. 각 항목은 name과 canonical Instagram 프로필 URL(알 수 없으면 null)을 가지며, 단순 재료·면·식자재 공급자나 납품업체는 참여자로 반환하지 마세요. " +
  "venue_name에는 행사가 실제로 열리는 장소만 반환하세요. 등록 매장과 같은 장소면 null로 반환하고, 외부 장소면 venue_address에는 명시된 주소만 반환하세요. venue_instagram_url에 명확히 연결된 canonical Instagram 프로필 URL만 반환하세요. venue_naver_map_url과 venue_kakao_map_url은 각각 그 외부 장소로 명확히 연결된 지도 URL일 때만 반환하세요. 게시물·릴 URL, 불명확한 계정, 또는 근거 없는 주소·지도 URL은 null로 반환하세요. " +
  "매장명은 계정명으로 추측하지 말고 실제 매장명이 원문에 명시된 경우에만 반환하세요. " +
  "관리자 피드백은 원문 사실을 더 정확히 반영하기 위한 수정 지시로만 사용하고 새로운 사실의 근거로 사용하지 마세요.";
const OPERATING_NOTICE_EXTRACTION_PROMPT =
  "라멘 매장의 영업 변동 공지 초안을 추출하세요. 입력에 없는 사실은 절대 만들지 마세요. " +
  "description은 원문 캡션 또는 이미지의 문구, 이모지, 구두점, 줄바꿈을 그대로 보존하세요. " +
  "요약·번역·홍보 문구로 재작성하지 말고, OCR이 불확실하면 읽은 내용을 임의로 보정하지 말고 uncertainties에 적으세요. " +
  "영업 변동은 전체 기능명이며 notice_type은 full_close(해당 날짜 전체 임시 휴무), early_close(정상 영업 중 수량 소진 등으로 실제 발생한 조기 마감), planned_close(사전에 정해진 사유에 따른 단축 영업인 운영 변동) 중 하나를 선택하세요. 특정 메뉴 품절만으로 매장 조기 마감으로 판단하지 마세요. 오픈 지연이나 일반 영업시간 변경은 유형을 null로 두고 uncertainties에 지원하지 않는 공지라고 적으세요. " +
  "월간 휴무 달력이나 떨어진 여러 휴무 날짜는 한 건의 full_close로 반환하고 daily_schedules에 원문에서 확인한 휴무 및 정상영업 날짜만 넣으세요. " +
  "daily_schedules의 closed는 휴무면 true, 정상영업이면 false입니다. 변경된 영업시간은 지원하지 않으며 각 schedule_override는 null입니다. " +
  "schedule_override와 start_time은 항상 null입니다. early_close와 planned_close의 end_time은 원문에 명시된 정확한 마감 시각만 넣으세요. 점심만 영업, 저녁 휴무, 지금 마감처럼 시각이 없으면 추측하지 말고 null로 두며 마감 시각 확인이 필요하다고 uncertainties에 적으세요. 월간 휴무 공지의 end_time은 null이고 start_date와 end_date는 daily_schedules에서 확인한 첫 날짜와 마지막 날짜입니다. " +
  "달력의 정상영업 표기도 빠짐없이 추출하되 빈칸의 의미를 추측하지 마세요. 단일 공지나 이벤트의 daily_schedules는 빈 배열입니다. " +
  "title은 null로 반환하세요. 날짜는 YYYY-MM-DD, 시간은 HH:mm으로 변환하세요. " +
  "오늘·내일 같은 상대 날짜는 게시일이나 관찰일을 알 수 없으면 추측하지 마세요. " +
  "명확한 하루 임시 휴무는 start_date와 end_date를 같은 날짜로 반환하고 daily_schedules는 빈 배열입니다. 그 외 종료일이 원문에 없으면 end_date를 null로 반환하고 uncertainties에 적으세요. " +
  "event_type은 null, participants는 빈 배열로 반환하세요. " +
  "매장명은 계정명으로 추측하지 말고 실제 매장명이 원문에 명시된 경우에만 반환하세요. " +
  "관리자 피드백은 원문 사실을 더 정확히 반영하기 위한 수정 지시로만 사용하고 새로운 사실의 근거로 사용하지 마세요.";

type RequestBody = { registration_type?: unknown; shop_name?: unknown; feedback?: unknown; source_url?: unknown; evidence_path?: unknown };
type EventDraft = {
  daily_schedules: DailySchedule[];
  shop_name: string | null;
  title: string | null;
  start_date: string | null;
  end_date: string | null;
  description: string | null;
  event_type: string | null;
  venue_name: string | null;
  venue_address: string | null;
  venue_instagram_url: string | null;
  venue_naver_map_url: string | null;
  venue_kakao_map_url: string | null;
  participants: EventParticipant[];
  uncertainties: string[];
  notice_type: string | null;
  start_time: string | null;
  end_time: string | null;
  schedule_override: { closed: boolean; open: string | null; close: string | null; close_next_day: boolean; label: string | null; break_times: Array<{ start: string; end: string }> } | null;
};
type EventParticipant = { name: string; instagram_url: string | null };
type InstagramCaption = { cleanText: string; handle: string | null; isExact: boolean };

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ code: "method_not_allowed" }, 405);
  if (!await isAdministrator(request)) return json({ code: "administrator_required" }, 403);

  const body = await request.json().catch(() => null) as RequestBody | null;
  const registrationType = text(body?.registration_type) ?? "event";
  let sourceUrl = normalizeInstagramUrl(text(body?.source_url));
  const requestedShopName = text(body?.shop_name);
  const feedback = text(body?.feedback)?.slice(0, 1_000) ?? null;
  const evidencePath = text(body?.evidence_path);
  if (!sourceUrl && !evidencePath) return json({ code: "input_required" }, 400);
  if (!isSupportedRegistrationType(registrationType)) return json({ code: "invalid_registration_type" }, 400);
  if (sourceUrl && !isInstagramUrl(sourceUrl)) return json({ code: "invalid_source_url" }, 400);

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) return json({ code: "analysis_unavailable" }, 503);

  try {
    const supabase = createServiceClient();
    const imageUrl = await createEvidenceUrl(supabase, evidencePath);
    const caption = sourceUrl ? await fetchInstagramCaption(sourceUrl) : null;
    const draft = await analyze(apiKey, registrationType, caption?.cleanText ?? null, imageUrl, feedback);
    if (caption?.isExact) draft.description = caption.cleanText;
    if (registrationType === "operating_notice") {
      if (draft.daily_schedules.length > 0) {
        normalizeClosureSchedule(draft);
        draft.schedule_override = null;
        draft.start_time = null;
        draft.end_time = null;
      }
      if ((draft.notice_type === "early_close" || draft.notice_type === "planned_close") && !draft.end_time) draft.uncertainties.push(`${draft.notice_type === "planned_close" ? "운영 변동의 마감" : "조기 마감"} 시각을 확인한 뒤 등록해 주세요.`);
      draft.event_type = null;
      draft.participants = [];
      if (!isSupportedNoticeType(draft.notice_type)) {
        draft.notice_type = null;
        draft.uncertainties.push("영업 변동 유형을 확인하지 못했습니다.");
      }
    } else if (!isSupportedEventType(draft.event_type)) {
      draft.event_type = "limited_menu";
      draft.uncertainties.push("이벤트 유형을 확인하지 못해 한정 메뉴로 분류했습니다.");
    }
    draft.venue_instagram_url = normalizeInstagramProfileUrl(draft.venue_instagram_url);
    draft.venue_naver_map_url = normalizeMapUrl(draft.venue_naver_map_url, "naver");
    draft.venue_kakao_map_url = normalizeMapUrl(draft.venue_kakao_map_url, "kakao");
    if (!draft.venue_name) {
      draft.venue_address = null;
      draft.venue_instagram_url = null;
      draft.venue_naver_map_url = null;
      draft.venue_kakao_map_url = null;
    }
    const resolvedShop = await resolveShop(supabase, caption?.handle, [requestedShopName, draft.shop_name]);
    if (resolvedShop) {
      draft.shop_name = resolvedShop.name;
      if (!sourceUrl) sourceUrl = normalizeInstagramProfileUrl(resolvedShop.instagramUrl);
    } else {
      draft.shop_name = null;
      draft.uncertainties.push("등록된 매장과 Instagram 계정을 확인하지 못했습니다.");
    }

    if (!caption && !imageUrl) draft.uncertainties.push("분석할 공개 캡션이나 이미지가 없습니다.");
    return json({ ...draft, source_url: sourceUrl, evidence_path: evidencePath });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error("preview-event failed", detail);
    return json({ code: "analysis_failed" }, 502);
  }
});

function normalizeClosureSchedule(draft: EventDraft) {
  const dates = draft.daily_schedules.map((day) => day?.date).filter(validCalendarDate).sort();
  const start = dates[0];
  const end = dates[dates.length - 1];
  if (!start || !end || !validClosureSchedules(draft.daily_schedules, start, end)) {
    console.error("preview-event invalid closure schedule");
    draft.daily_schedules = [];
    draft.start_date = null;
    draft.end_date = null;
    draft.notice_type = null;
    return;
  }
  draft.start_date = start;
  draft.end_date = end;
  draft.notice_type = "full_close";
  if (draft.daily_schedules.length === 1) draft.daily_schedules = [];
}

async function analyze(
  apiKey: string,
  registrationType: string,
  caption: string | null,
  imageUrl: string | null,
  feedback: string | null,
): Promise<EventDraft> {
  const context = [
    caption ? `Instagram 공개 캡션:\n${caption}` : "공개 캡션 없음",
    imageUrl ? "첨부 이미지는 스토리 또는 게시물 원문입니다. 이미지에 실제로 보이는 텍스트만 사용하세요." : null,
    feedback ? `관리자 피드백:\n${feedback}` : null,
    "입력에 없는 값은 추측하지 말고 null로 반환하세요.",
  ].filter(Boolean).join("\n\n");
  const content: Array<Record<string, unknown>> = [{ type: "text", text: context }];
  if (imageUrl) content.push({ type: "image_url", image_url: { url: imageUrl, detail: "high" } });

  const response = await fetch(OPENAI_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: Deno.env.get("AI_MODEL") ?? "gpt-4o-mini",
      temperature: 0,
      messages: [
        {
          role: "system",
          content: registrationType === "operating_notice"
            ? "라멘 매장의 영업 변동 공지 초안을 추출하세요. 입력에 없는 사실은 절대 만들지 마세요. 유형은 full_close, early_close, planned_close를 지원합니다. 정상 영업 도중 실제로 일찍 종료한 경우 early_close, 사전 공지한 점심만 영업 또는 저녁 휴무는 planned_close로 분류하되 원문에 정확한 마감 시각이 없으면 end_time을 null로 두고 uncertainties에 확인 필요를 적으세요. start_time과 schedule_override는 항상 null입니다. 월간 휴무 공지는 full_close와 daily_schedules를 사용하세요."
            : "라멘 매장의 이벤트 등록 초안을 추출하세요. 입력에 없는 사실은 절대 만들지 마세요. 관리자 피드백은 입력 사실을 더 정확히 반영하기 위한 수정 지시로만 사용하고, 새로운 사실을 추측하는 근거로 사용하지 마세요. title은 원문에 명시된 이벤트명이나 메뉴명만 짧게 적고, 원문에 없으면 null을 반환하세요. event_type은 collab, popup, limited_menu, summer_limited, new_menu, store_renewal 중 하나입니다. 다른 매장·브랜드·셰프 등이 이벤트에 함께 참여하거나 콜라보한다고 명시된 경우에만 collab을 선택하세요. participants에는 원문에서 이벤트 참여 또는 콜라보가 명시된 주체만 넣고, 각 항목에 name과 canonical Instagram 프로필 URL(알 수 없으면 null)을 넣으세요. 단순 재료·면·식자재 공급자나 납품업체는 참여자가 아닙니다. 날짜·회식·메뉴·수량·운영 시간을 추측하거나 추가하지 마세요. description은 입력 캡션의 사실만 사용하고 홍보 문구로 바꾸지 마세요. 매장명은 계정명이 아니라 실제 매장명으로 추측하지 말고 null을 반환하세요. 날짜는 YYYY-MM-DD로 변환합니다. 확실하지 않거나 누락된 필드는 uncertainties에 한국어로 적습니다.",
        },
        {
          role: "system",
          content: registrationType === "operating_notice"
            ? OPERATING_NOTICE_EXTRACTION_PROMPT
            : EVENT_EXTRACTION_PROMPT,
        },
        { role: "user", content },
      ],
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "event_draft",
          strict: true,
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              shop_name: { type: ["string", "null"] },
              title: { type: ["string", "null"] },
              start_date: { type: ["string", "null"] },
              end_date: { type: ["string", "null"] },
              description: { type: ["string", "null"] },
              event_type: { type: ["string", "null"] },
              venue_name: { type: ["string", "null"] }, venue_address: { type: ["string", "null"] }, venue_instagram_url: { type: ["string", "null"] }, venue_naver_map_url: { type: ["string", "null"] }, venue_kakao_map_url: { type: ["string", "null"] },
              participants: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    instagram_url: { type: ["string", "null"] },
                  },
                  required: ["name", "instagram_url"],
                },
              },
              notice_type: { type: ["string", "null"] },
              start_time: { type: ["string", "null"] },
              end_time: { type: ["string", "null"] },
              schedule_override: { type: ["object", "null"], additionalProperties: false, properties: { closed: { type: "boolean" }, open: { type: ["string", "null"] }, close: { type: ["string", "null"] }, close_next_day: { type: "boolean" }, label: { type: ["string", "null"] }, break_times: { type: "array", items: { type: "object", additionalProperties: false, properties: { start: { type: "string" }, end: { type: "string" } }, required: ["start", "end"] } } }, required: ["closed", "open", "close", "close_next_day", "label", "break_times"] },
              daily_schedules: dailySchedulesSchema,
              uncertainties: { type: "array", items: { type: "string" } },
            },
            required: ["shop_name", "title", "start_date", "end_date", "description", "event_type", "venue_name", "venue_address", "venue_instagram_url", "venue_naver_map_url", "venue_kakao_map_url", "participants", "notice_type", "start_time", "end_time", "schedule_override", "daily_schedules", "uncertainties"],
          },
        },
      },
    }),
  });
  if (!response.ok) throw new Error(`OpenAI analysis failed: ${response.status} ${await response.text()}`);
  const payload = await response.json() as { choices?: Array<{ message?: { content?: string } }> };
  const outputText = payload.choices?.[0]?.message?.content;
  if (!outputText) throw new Error("OpenAI returned no structured output");
  const draft = JSON.parse(outputText) as EventDraft;
  return {
    daily_schedules: registrationType === "operating_notice" && Array.isArray(draft.daily_schedules) ? draft.daily_schedules : [],
    shop_name: text(draft.shop_name),
    title: text(draft.title),
    start_date: validDate(draft.start_date) ? draft.start_date : null,
    end_date: validDate(draft.end_date) ? draft.end_date : null,
    description: text(draft.description),
    event_type: text(draft.event_type),
    venue_name: text(draft.venue_name), venue_address: text(draft.venue_address), venue_instagram_url: normalizeInstagramProfileUrl(text(draft.venue_instagram_url)), venue_naver_map_url: normalizeMapUrl(draft.venue_naver_map_url, "naver"), venue_kakao_map_url: normalizeMapUrl(draft.venue_kakao_map_url, "kakao"),
    participants: Array.isArray(draft.participants)
      ? draft.participants.flatMap((participant) => {
        const name = text(participant?.name);
        return name ? [{ name, instagram_url: normalizeInstagramProfileUrl(text(participant?.instagram_url)) }] : [];
      })
      : [],
    notice_type: text(draft.notice_type),
    start_time: null,
    end_time: (draft.notice_type === "early_close" || draft.notice_type === "planned_close") && validTime(draft.end_time) ? draft.end_time : null,
    schedule_override: null,
    uncertainties: Array.isArray(draft.uncertainties) ? draft.uncertainties.filter((item) => typeof item === "string") : [],
  };
}

async function createEvidenceUrl(supabase: ReturnType<typeof createServiceClient>, path: string | null) {
  if (!path || !/^[\w-]+\.(?:jpe?g|png)$/i.test(path)) return null;
  const { data, error } = await mediaStorage(supabase).from(EVIDENCE_BUCKET).createSignedUrl(path, 300);
  if (error) throw error;
  return data.signedUrl;
}

async function fetchInstagramCaption(sourceUrl: string): Promise<InstagramCaption | null> {
  const response = await fetch(sourceUrl, { headers: { "User-Agent": "Mozilla/5.0" } }).catch(() => null);
  if (!response?.ok) return null;
  const html = await response.text();
  const match = html.match(/<meta\b[^>]*(?:name|property)=["'](?:description|og:description)["'][^>]*content=["']([^"']*)["'][^>]*>/i);
  if (!match) return null;
  const rawText = decodeHtml(match[1]);
  const prefix = rawText.match(/^\s*[\d,.]+\s+likes?,\s*[\d,.]+\s+comments?\s+-\s*([A-Za-z0-9._]+)\s+on\s+[^:]+:\s*/i);
  if (!prefix) return { cleanText: rawText.trim(), handle: null, isExact: false };
  const cleanText = rawText.slice(prefix[0].length).replace(/^["“]|["”]\s*\.?\s*$/g, "").trim();
  return {
    cleanText: cleanText || rawText.trim(),
    handle: prefix[1].toLowerCase(),
    isExact: cleanText.length > 0,
  };
}

async function resolveShop(
  supabase: ReturnType<typeof createServiceClient>,
  handle: string | null | undefined,
  candidates: Array<string | null>,
) {
  const findByName = async (candidate: string) => {
    const { data } = await supabase.from("ramen_shops").select("name,instagram_url").eq("name", candidate).limit(2);
    return data?.length === 1 ? { name: data[0].name as string, instagramUrl: data[0].instagram_url as string | null } : null;
  };
  for (const candidate of candidates) {
    if (candidate) {
      const shop = await findByName(candidate);
      if (shop) return shop;
    }
  }
  const handles = handle ? [
    `https://www.instagram.com/${handle}`,
    `https://www.instagram.com/${handle}/`,
    `https://instagram.com/${handle}`,
    `https://instagram.com/${handle}/`,
  ] : [];
  if (handles.length > 0) {
    const { data } = await supabase.from("ramen_shops").select("name,instagram_url").in("instagram_url", handles).limit(2);
    if (data?.length === 1) return { name: data[0].name as string, instagramUrl: data[0].instagram_url as string | null };
  }
  return null;
}

function isInstagramUrl(value: string) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && (url.hostname === "instagram.com" || url.hostname.endsWith(".instagram.com"));
  } catch {
    return false;
  }
}

function normalizeInstagramUrl(value: string | null) {
  if (!value) return null;
  const match = value.match(/https?:\/\/(?:www\.)?instagram\.com\/(p|reel)\/([^/?#\s\]"']+)/i);
  if (!match) return null;
  return `https://www.instagram.com/${match[1].toLowerCase()}/${match[2]}/`;
}
function normalizeInstagramProfileUrl(value: string | null) {
  if (!value) return null;
  const match = value.match(/^https?:\/\/(?:www\.)?instagram\.com\/([^/?#\s\]"']+)\/?(?:[?#].*)?$/i);
  if (!match || ["p", "reel"].includes(match[1].toLowerCase())) return null;
  return `https://www.instagram.com/${match[1]}/`;
}

function isSupportedRegistrationType(value: string) { return value === "event" || value === "operating_notice"; }
function isSupportedEventType(value: string | null) { return value === "collab" || value === "popup" || value === "limited_menu" || value === "summer_limited" || value === "new_menu" || value === "store_renewal"; }
function isSupportedNoticeType(value: string | null) { return value === "full_close" || value === "early_close" || value === "planned_close"; }
function validDate(value: string | null) { return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value); }
function validTime(value: string | null) { return typeof value === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(value); }
function text(value: unknown): string | null { return typeof value === "string" && value.trim() !== "" ? value.trim() : null; }
function decodeHtml(value: string) {
  return value
    .replace(/&#x([\da-f]+);/gi, (_, code: string) => String.fromCodePoint(parseInt(code, 16)))
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number(code)))
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">");
}
function json(body: Record<string, unknown>, status = 200): Response { return Response.json(body, { status }); }
