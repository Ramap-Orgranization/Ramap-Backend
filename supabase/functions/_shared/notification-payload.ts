import { automaticOperatingNoticeCopy } from "./operating-notice-copy.ts";

export type Destination =
  | { version: 1; action: "event_detail"; event_id: string }
  | { version: 1; action: "operating_notices" | "none" }
  | { version: 1; action: "external_url"; url: string };

export type PublicationFact = {
  id: string;
  shop_id: string;
  shop_name: string;
  type_id: string;
  verified: boolean;
  certainty: "confirmed" | "planned" | "unknown";
  starts_on: string | null;
  ends_on: string | null;
  starts_at: string | null;
  ends_at: string | null;
  time_meaning: "full_day" | "partial_day" | "opening" | "last_order" | "closing" | "waitlist_end" | "unspecified";
  exception_dates: string[];
  message: string;
  // A reviewed sentence already includes its shop/date/time/conditions.
  message_format?: "sentence";
  notification_title?: string;
  context_key: string;
  destination: Destination;
  registration_type: "event" | "operating_notice" | "none";
  registration_id: string | null;
};
export type PushPayload = { notification: { title: string; body: string }; data: Record<string, string> };
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TIME_LABELS: Record<PublicationFact["time_meaning"], string> = {
  full_day: "종일", partial_day: "시간대 한정", opening: "오픈", last_order: "라스트오더",
  closing: "마감", waitlist_end: "웨이팅 접수 종료", unspecified: "시간 안내",
};

export function validOfficialUrl(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 2048 || !value.startsWith("https://")) return false;
  if (/[\s\\"<>\u0000-\u001f\u007f]/u.test(value) || /%(?![0-9a-f]{2})/i.test(value) || /%(?:0[0-9a-f]|1[0-9a-f]|7f|5c|25)/i.test(value)) return false;
  try {
    decodeURIComponent(value);
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.hash || (url.port && url.port !== "443")) return false;
    const authority = value.slice(8).split(/[/?#]/, 1)[0];
    if (!/^[A-Za-z0-9.-]+(?::443)?$/.test(authority)) return false;
    const host = url.hostname;
    if (host.length > 253 || !host.includes(".") || /^[0-9.]+$/.test(host)) return false;
    if (/(?:^|\.)(?:localhost|local|internal|test|invalid|example|onion|lan|home|intranet|corp)$/.test(host)) return false;
    return host.split(".").every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label));
  } catch { return false; }
}

export function validDestination(value: unknown, sourceUrl: string): value is Destination {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Record<string, unknown>;
  if (item.version !== 1) return false;
  if (item.action === "event_detail") return typeof item.event_id === "string" && UUID.test(item.event_id) && Object.keys(item).every((key) => ["version", "action", "event_id"].includes(key));
  if (item.action === "external_url") return item.url === sourceUrl && validOfficialUrl(item.url) && Object.keys(item).every((key) => ["version", "action", "url"].includes(key));
  return ["operating_notices", "none"].includes(String(item.action)) && Object.keys(item).every((key) => ["version", "action"].includes(key));
}

export function validDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export function validateFact(value: unknown, sourceUrl: string): PublicationFact {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_fact");
  const fact = value as PublicationFact;
  if (!UUID.test(fact.id) || !UUID.test(fact.shop_id) || !/^[a-z][a-z0-9_]{0,63}$/.test(fact.type_id)) throw new Error("invalid_fact_identity");
  for (const [text, limit] of [[fact.shop_name, 100], [fact.message, 500], [fact.context_key, 100]] as const) {
    if (typeof text !== "string" || !text.trim() || text.length > limit || /[\u0000-\u001f\u007f]/.test(text)) throw new Error("invalid_fact_text");
  }
  if (fact.message_format !== undefined && fact.message_format !== "sentence") throw new Error("invalid_message_format");
  if (fact.notification_title !== undefined && (fact.message_format !== "sentence"
    || typeof fact.notification_title !== "string" || !fact.notification_title.trim() || fact.notification_title.length > 100
    || /[\u0000-\u001f\u007f]/.test(fact.notification_title))) throw new Error("invalid_notification_title");
  if (typeof fact.verified !== "boolean" || !["confirmed", "planned", "unknown"].includes(fact.certainty)) throw new Error("invalid_fact_certainty");
  if (fact.starts_on !== null && !validDate(fact.starts_on)) throw new Error("invalid_fact_date");
  if (fact.ends_on !== null && (!validDate(fact.ends_on) || !fact.starts_on || fact.ends_on < fact.starts_on)) throw new Error("invalid_fact_date");
  for (const time of [fact.starts_at, fact.ends_at]) if (time !== null && (typeof time !== "string" || !/^([01]\d|2[0-3]):[0-5]\d$/.test(time))) throw new Error("invalid_fact_time");
  if (!Object.hasOwn(TIME_LABELS, fact.time_meaning)) throw new Error("invalid_time_meaning");
  if (fact.time_meaning === "full_day" && (fact.starts_at || fact.ends_at)) throw new Error("full_day_cannot_have_partial_time");
  if (!Array.isArray(fact.exception_dates) || fact.exception_dates.length > 62 || fact.exception_dates.some((date) => !validDate(date))) throw new Error("invalid_exception_dates");
  if (new Set(fact.exception_dates).size !== fact.exception_dates.length) throw new Error("duplicate_exception_dates");
  if (!validDestination(fact.destination, sourceUrl)) throw new Error("invalid_destination");
  if (!["event", "operating_notice", "none"].includes(fact.registration_type)) throw new Error("invalid_registration_type");
  if (fact.registration_type === "none" ? fact.registration_id !== null : !UUID.test(fact.registration_id ?? "")) throw new Error("invalid_registration_id");
  if (fact.type_id === "event" && (fact.registration_type !== "event" || fact.destination.action !== "event_detail" || fact.destination.event_id !== fact.registration_id)) throw new Error("event_registration_required");
  return fact;
}

export function assertCompatibleFacts(facts: PublicationFact[]): void {
  if (!facts.length) return;
  if (new Set(facts.map((fact) => fact.context_key)).size !== 1) throw new Error("split_required");
  const sameInterval = new Set(facts.map((fact) => `${fact.starts_on}/${fact.ends_on}`)).size === 1;
  const monthlyClosures = facts.every((fact) => fact.type_id === "temporary_closure" && fact.time_meaning === "full_day" && fact.starts_on && fact.ends_on
    && fact.starts_on.slice(0, 7) === facts[0].starts_on?.slice(0, 7) && fact.ends_on.slice(0, 7) === facts[0].starts_on?.slice(0, 7))
    && new Set(facts.map((fact) => fact.shop_id)).size === 1;
  if (!sameInterval && !monthlyClosures) throw new Error("split_required");
}

function factSection(fact: PublicationFact): string {
  const dates = fact.starts_on ? fact.starts_on + (fact.ends_on && fact.ends_on !== fact.starts_on ? ` ~ ${fact.ends_on}` : "") : "날짜 미정";
  const times = [fact.starts_at, fact.ends_at].filter(Boolean).join(" ~ ");
  const meaning = fact.time_meaning === "unspecified" && !times ? "" : ` · ${TIME_LABELS[fact.time_meaning]}${times ? ` ${times}` : ""}`;
  const exceptions = fact.exception_dates.length ? ` · 제외 ${fact.exception_dates.join(", ")}` : "";
  return `[${fact.shop_name} · ${dates}${meaning}${fact.certainty === "planned" ? " · 예정" : ""}${exceptions}] ${fact.message}`;
}

export function buildPublicationPayload(input: {
  notificationId: string; facts: PublicationFact[]; protocol: number; sourceUrl: string; correction?: boolean; cancelled?: boolean;
}): PushPayload | null {
  if (!UUID.test(input.notificationId)) throw new Error("invalid_notification_id");
  let facts = input.facts.filter((fact) => fact.verified && fact.certainty !== "unknown");
  if (input.protocol < 1) facts = facts.filter((fact) => fact.type_id === "event" && fact.destination.action === "event_detail");
  if (!facts.length) return null;
  assertCompatibleFacts(facts);
  const unique = new Map(facts.map((fact) => [fact.id, fact]));
  facts = [...unique.values()];
  const destinations = [...new Set(facts.map((fact) => JSON.stringify(fact.destination)))];
  if (input.protocol < 1 && destinations.length !== 1) return null;
  const destination: Destination = destinations.length === 1 ? facts[0].destination : { version: 1, action: "none" };
  // Reviewed copy is separate from source text. Automatic notices use only
  // verified structured facts, while corrections retain their reviewed wording.
  const copies = facts.map((fact) => fact.message_format === "sentence"
    ? { title: fact.notification_title ?? "영업 변동 안내", body: fact.message }
    : !input.cancelled && !input.correction ? automaticOperatingNoticeCopy(fact) : null);
  const sentenceCopy = copies.every((copy) => copy !== null);
  const titles = new Set(copies.filter((copy) => copy !== null).map((copy) => copy.title));
  const title = input.cancelled ? "공지 취소 안내" : input.correction ? "공지 정정 안내"
    : sentenceCopy ? (titles.size === 1 ? copies[0]!.title : "새 매장 소식") : "새 매장 소식";
  // Legacy reviewed fragments retain their exact dates and time meanings.
  const body = facts.map((fact, index) => copies[index]?.body ?? factSection(fact)).join(" · ");
  const noticeIds = [...new Set(facts.map((fact) => fact.registration_type === "operating_notice" ? fact.registration_id : null))];
  const outboundDestination = input.protocol >= 2 && destination.action === "operating_notices" && noticeIds.length === 1 && noticeIds[0]
    ? { version: 2, action: "operating_notices", notice_id: noticeIds[0] }
    : destination;
  const deepLink = input.protocol >= 1 ? JSON.stringify(outboundDestination)
    : `ramap://notification/event?event_id=${encodeURIComponent((destination as { event_id: string }).event_id)}`;
  const data: Record<string, string> = { notification_id: input.notificationId, notification_type: "publication", deep_link: deepLink };
  if (input.protocol < 1) {
    data.notification_type = "new_event";
    data.event_id = (destination as { event_id: string }).event_id;
  }
  const payload = { notification: { title, body }, data };
  if (new TextEncoder().encode(JSON.stringify(payload)).length > 3500) throw new Error("personalized_payload_too_large");
  return payload;
}
