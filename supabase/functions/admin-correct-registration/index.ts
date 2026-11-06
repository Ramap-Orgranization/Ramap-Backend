import { effectiveEndDate, isManageableEvent } from "../_shared/admin-event-policy.ts";
import { isAdministrator } from "../_shared/admin-auth.ts";
import { createServiceClient } from "../_shared/event-notifications.ts";

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const EVENT_TYPES = ["collab", "popup", "limited_menu", "summer_limited", "new_menu", "store_renewal"] as const;
const NOTICE_TYPES = ["full_close", "early_close", "planned_close"] as const;
type RegistrationType = "event" | "operating_notice";
type Changes = {
  title: string | null; description: string | null; start_date: string | null; end_date: string | null;
  event_type: string | null; notice_type: string | null; start_time: string | null; end_time: string | null; schedule_override: unknown | null;
};

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ code: "method_not_allowed" }, 405);
  if (!await isAdministrator(request)) return json({ code: "administrator_required" }, 403);
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (body?.action === "preview") return previewCorrection(text(body.request));
  const registrationType = body?.registration_type, targetId = text(body?.target_id);
  if (!isRegistrationType(registrationType) || !targetId) return json({ code: "invalid_target" }, 400);
  if (body.action === "apply") return applyCorrection(registrationType, targetId, body.changes);
  return json({ code: "invalid_action" }, 400);
});

async function previewCorrection(instruction: string | null) {
  if (!instruction || instruction.length > 1_000) return json({ code: "invalid_request" }, 400);
  const supabase = createServiceClient();
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) return json({ code: "analysis_unavailable" }, 503);
  try {
    const target = await parseTarget(apiKey, instruction);
    if (!target.shop_name || (!target.title_context && !target.notice_date)) return json({ code: "target_context_required" }, 422);
    const candidates = await findActiveCandidates(supabase, target);
    if (candidates.length !== 1) return json({ code: candidates.length ? "ambiguous_target" : "active_target_not_found" }, 422);
    const candidate = candidates[0];
    const record = await findRecord(supabase, candidate.registration_type, candidate.id);
    if (!record) return json({ code: "active_target_not_found" }, 404);
    const result = await analyze(apiKey, candidate.registration_type, record, instruction);
    const changes = validateChanges(candidate.registration_type, result.changes);
    if (!changes) return json({ code: "unsupported_correction" }, 422);
    return json({ registration_type: candidate.registration_type, target_id: candidate.id, summary: result.summary, changes });
  } catch (error) {
    console.error("admin-correct-registration preview failed", error);
    return json({ code: "analysis_failed" }, 502);
  }
}

type Target = { shop_name: string | null; title_context: string | null; registration_type: RegistrationType | null; notice_date: string | null };
type Candidate = { id: string; registration_type: RegistrationType };

async function parseTarget(apiKey: string, instruction: string): Promise<Target> {
  const response = await fetch(OPENAI_URL, {
    method: "POST", headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: Deno.env.get("AI_MODEL") ?? "gpt-4o-mini", temperature: 0, messages: [{ role: "system", content: "수정 요청에서 대상 매장명, 이벤트 제목 또는 영업공지 맥락, 유형을 추출하세요. 명시되지 않은 값은 null입니다. 유형은 event 또는 operating_notice입니다. notice_date에는 수정 대상인 기존 영업 공지의 날짜를 YYYY-MM-DD로 반환하세요. 정확한 연월일이 명시되지 않으면 null로 두고 새로운 적용일과 혼동하지 마세요." }, { role: "user", content: instruction }], response_format: { type: "json_schema", json_schema: { name: "registration_target", strict: true, schema: { type: "object", additionalProperties: false, properties: { notice_date: { type: ["string", "null"] }, shop_name: { type: ["string", "null"] }, title_context: { type: ["string", "null"] }, registration_type: { type: ["string", "null"], enum: ["event", "operating_notice", null] } }, required: ["shop_name", "title_context", "registration_type", "notice_date"] } } } }),
  });
  if (!response.ok) throw new Error(`OpenAI target parse failed: ${response.status}`);
  const content = (await response.json() as { choices?: Array<{ message?: { content?: string } }> }).choices?.[0]?.message?.content;
  if (!content) throw new Error("OpenAI returned no target");
  const target = JSON.parse(content) as Target;
  const noticeDate = target.notice_date && validDate(target.notice_date) ? target.notice_date : null;
  return { shop_name: text(target.shop_name), title_context: text(target.title_context), registration_type: isRegistrationType(target.registration_type) ? target.registration_type : noticeDate ? "operating_notice" : null, notice_date: noticeDate };
}

async function findActiveCandidates(supabase: ReturnType<typeof createServiceClient>, target: Target): Promise<Candidate[]> {
  const { data: shops, error } = await supabase.from("ramen_shops").select("id").ilike("name", `%${escapeLike(target.shop_name)}%`).limit(3);
  if (error || !shops?.length) return [];
  const shopIds = shops.map((shop) => shop.id), today = koreaToday();
  const [events, notices] = await Promise.all([
    target.registration_type === "operating_notice" ? Promise.resolve({ data: [] }) : supabase.from("shop_events").select("id,title,event_type,start_date,end_date").in("shop_id", shopIds).ilike("title", `%${escapeLike(target.title_context ?? "")}%`).or(`end_date.is.null,end_date.gte.${today}`).limit(100),
    target.registration_type === "event" ? Promise.resolve({ data: [] }) : supabase.from("shop_operating_notices").select("id,notice_type,description,notice_date,end_date").in("shop_id", shopIds).or(`and(end_date.is.null,notice_date.gte.${today}),end_date.gte.${today}`).limit(100),
  ]);
  const matches = [
    ...(events.data ?? []).filter((event) => isManageableEvent(event, today) && matchesContext(event.title, target.title_context)).map((event) => ({ id: event.id, registration_type: "event" as const })),
    ...(notices.data ?? []).filter((notice) => matchesContext(`${notice.notice_type} ${notice.description ?? ""}`, target.title_context) && matchesNoticeDate(notice, target.notice_date)).map((notice) => ({ id: notice.id, registration_type: "operating_notice" as const })),
  ];
  return matches;
}

function matchesNoticeDate(notice: { notice_date: string; end_date: string | null }, date: string | null): boolean {
  return !date || (notice.notice_date <= date && date <= (notice.end_date ?? notice.notice_date));
}

function matchesContext(value: string, context: string | null): boolean { return !context || value.toLowerCase().includes(context.toLowerCase()); }
function escapeLike(value: string): string { return value.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_"); }

async function applyCorrection(type: RegistrationType, id: string, value: unknown) {
  const changes = validateChanges(type, value);
  if (!changes) return json({ code: "invalid_changes" }, 400);
  const current = await findRecord(createServiceClient(), type, id);
  if (!current || !isActiveRecord(type, current)) return json({ code: "active_target_not_found" }, 404);
  const startDate = changes.start_date ?? (type === "event" ? current.start_date : current.notice_date) as string;
  const eventType = changes.event_type ?? current.event_type as string;
  const endDate = type === "event" && eventType === "new_menu"
    ? effectiveEndDate({ event_type: eventType, start_date: startDate, end_date: null })
    : type === "event" && eventType === "store_renewal" ? null : changes.end_date ?? current.end_date as string | null;
  if (!validDate(startDate) || (endDate !== null && (!validDate(endDate) || startDate > endDate))) {
    return json({ code: "invalid_date_range" }, 400);
  }
  const update = type === "event"
    ? { title: changes.title, description: changes.description, start_date: changes.start_date, end_date: changes.end_date, event_type: changes.event_type }
    : { description: changes.description, notice_date: changes.start_date, end_date: changes.end_date, notice_type: changes.notice_type, start_time: changes.start_time, end_time: changes.end_time, schedule_override: changes.schedule_override };
  const filtered = Object.fromEntries(Object.entries(update).filter(([, value]) => value !== null));
  if (type === "event" && (eventType === "new_menu" || eventType === "store_renewal")) filtered.end_date = endDate;
  if (type === "operating_notice") {
    const noticeType = changes.notice_type ?? current.notice_type;
    const endTime = changes.end_time ?? current.end_time;
    if (!NOTICE_TYPES.includes(noticeType as typeof NOTICE_TYPES[number]) || ((noticeType === "early_close" || noticeType === "planned_close") && !endTime)) return json({ code: "invalid_changes" }, 400);
    filtered.start_time = null;
    filtered.schedule_override = null;
    if (noticeType === "full_close") filtered.end_time = null;
  }
  if (Object.keys(filtered).length === 0) return json({ code: "no_supported_changes" }, 422);
  const table = type === "event" ? "shop_events" : "admin_shop_operating_notice_records";
  const { error } = await createServiceClient().from(table).update(filtered).eq("id", id);
  return error ? json({ code: "update_failed" }, 422) : json({ success: true });
}

async function findRecord(supabase: ReturnType<typeof createServiceClient>, type: RegistrationType, id: string) {
  const query = type === "event"
    ? supabase.from("shop_events").select("title,description,start_date,end_date,event_type").eq("id", id).maybeSingle()
    : supabase.from("admin_shop_operating_notice_records").select("description,notice_date,end_date,notice_type,start_time,end_time,schedule_override").eq("id", id).maybeSingle();
  const { data, error } = await query;
  return error || !data ? null : data;
}

function isActiveRecord(type: RegistrationType, record: Record<string, unknown>): boolean {
  const today = koreaToday(), endDate = text(record.end_date);
  if (type === "event") return isManageableEvent({ event_type: text(record.event_type) ?? "", start_date: text(record.start_date) ?? "", end_date: endDate }, today);
  return (endDate ?? text(record.notice_date) ?? "") >= today;
}

async function analyze(apiKey: string, type: RegistrationType, record: unknown, instruction: string): Promise<{ summary: string; changes: Changes }> {
  const response = await fetch(OPENAI_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: Deno.env.get("AI_MODEL") ?? "gpt-4o-mini",
      temperature: 0,
      messages: [{
        role: "system",
        content: `관리자 등록 수정 도우미입니다. ${type === "event" ? "이벤트는 title, description, start_date, end_date, event_type만" : "영업 변동은 description, start_date(원본 notice_date), end_date, notice_type, end_time만"} 변경할 수 있습니다. 공지 유형은 full_close(해당 날짜 전체 임시 휴무), early_close(정상 영업 중 수량 소진 등으로 실제 발생한 조기 마감), planned_close(사전에 정해진 사유에 따른 단축 영업인 운영 변동)를 지원합니다. 두 마감 유형은 원문에서 확인된 정확한 end_time이 필요하며 start_time과 schedule_override는 null입니다. 기존 레코드와 요청만 근거로 삼으세요.`,
      }, { role: "user", content: `기존 레코드:\n${JSON.stringify(record)}\n\n수정 요청:\n${instruction}` }],
      response_format: { type: "json_schema", json_schema: { name: "registration_correction", strict: true, schema: { type: "object", additionalProperties: false, properties: { summary: { type: "string" }, changes: { type: "object", additionalProperties: false, properties: { title: { type: ["string", "null"] }, description: { type: ["string", "null"] }, start_date: { type: ["string", "null"] }, end_date: { type: ["string", "null"] }, event_type: { type: ["string", "null"] }, notice_type: { type: ["string", "null"] }, start_time: { type: ["string", "null"] }, end_time: { type: ["string", "null"] }, schedule_override: { type: ["object", "null"], additionalProperties: false, properties: { closed: { type: "boolean" }, open: { type: ["string", "null"] }, close: { type: ["string", "null"] }, close_next_day: { type: "boolean" }, label: { type: ["string", "null"] } }, required: ["closed", "open", "close", "close_next_day", "label"] } }, required: ["title", "description", "start_date", "end_date", "event_type", "notice_type", "start_time", "end_time", "schedule_override"] } }, required: ["summary", "changes"] } } },
    }),
  });
  if (!response.ok) throw new Error(`OpenAI analysis failed: ${response.status}`);
  const payload = await response.json() as { choices?: Array<{ message?: { content?: string } }> };
  const content = payload.choices?.[0]?.message?.content;
  if (!content) throw new Error("OpenAI returned no content");
  return JSON.parse(content) as { summary: string; changes: Changes };
}

function validateChanges(type: RegistrationType, value: unknown): Changes | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const item = value as Record<string, unknown>;
  const changes: Changes = { title: nullableText(item.title), description: nullableText(item.description), start_date: nullableDate(item.start_date), end_date: nullableDate(item.end_date), event_type: nullableText(item.event_type), notice_type: nullableText(item.notice_type), start_time: nullableTime(item.start_time), end_time: nullableTime(item.end_time), schedule_override: item.schedule_override ?? null };
  if (Object.entries(item).some(([key, value]) => key !== "schedule_override" && value !== null && value !== undefined && typeof value !== "string")) return null;
  if (changes.start_date === "" || changes.end_date === "" || changes.start_time === "" || changes.end_time === "") return null;
  if (changes.event_type && !EVENT_TYPES.includes(changes.event_type as typeof EVENT_TYPES[number])) return null;
  if (changes.notice_type && !NOTICE_TYPES.includes(changes.notice_type as typeof NOTICE_TYPES[number])) return null;
  if (type === "event") {
    changes.notice_type = changes.start_time = changes.end_time = changes.schedule_override = null;
  } else {
    changes.title = changes.event_type = null;
    if (changes.schedule_override !== null || changes.start_time !== null) return null;
  }
  return Object.values(changes).some((value) => value !== null) ? changes : null;
}

function isRegistrationType(value: unknown): value is RegistrationType { return value === "event" || value === "operating_notice"; }
function text(value: unknown): string | null { return typeof value === "string" && value.trim() ? value.trim() : null; }
function nullableText(value: unknown): string | null { return value === null ? null : text(value); }
function nullableDate(value: unknown): string | null | "" { return value == null ? null : typeof value === "string" && validDate(value) ? value : ""; }
function nullableTime(value: unknown): string | null | "" { return value == null ? null : typeof value === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(value) ? value : ""; }
function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().startsWith(value);
}
function koreaToday(): string {
  const parts = new Intl.DateTimeFormat("en", { timeZone: "Asia/Seoul", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts();
  return `${parts.find((part) => part.type === "year")!.value}-${parts.find((part) => part.type === "month")!.value}-${parts.find((part) => part.type === "day")!.value}`;
}
function json(body: unknown, status = 200): Response { return Response.json(body, { status }); }
