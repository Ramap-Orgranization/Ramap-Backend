import type { PublicationFact } from "./notification-payload.ts";

export type OperatingNoticeCopy = { title: string; body: string };

// Automatic registrations have structured dates and hours, but their description
// is the preserved shop announcement, not reviewed push copy. Never append it.
export function automaticOperatingNoticeCopy(fact: PublicationFact): OperatingNoticeCopy | null {
  if (fact.registration_type !== "operating_notice" || fact.id !== fact.registration_id
    || fact.context_key !== `operating-notice-${fact.registration_id}`) return null;
  if (!fact.starts_on || !fact.ends_on || fact.certainty !== "confirmed" || fact.exception_dates.length
    || fact.starts_at || hasUnstructuredConditions(fact.message) || hasConflictingClock(fact)) throw new Error("operating_notice_copy_review_required");

  const subject = shopTopic(fact.shop_name);
  const date = dateRange(fact.starts_on, fact.ends_on);
  if (fact.type_id === "temporary_closure" && fact.time_meaning === "full_day" && !fact.ends_at) {
    return { title: "임시휴무 안내", body: `${subject} ${date} ${fact.starts_on === fact.ends_on ? "하루 " : ""}쉬어요.` };
  }
  if ((fact.type_id === "early_closing" || fact.type_id === "shortened_hours")
    && fact.time_meaning === "closing" && fact.ends_at) {
    const time = clockTime(fact.ends_at);
    return fact.type_id === "early_closing"
      ? { title: "조기 마감 안내", body: `${subject} ${date} ${time}에 일찍 마감해요.` }
      : { title: "단축 영업 안내", body: `${subject} ${date} ${time}까지 영업해요.` };
  }
  throw new Error("operating_notice_copy_review_required");
}

function hasUnstructuredConditions(message: string): boolean {
  // These scopes cannot safely be reconstructed from the legacy single interval.
  // Leave them in the queue for an explicitly reviewed publication instead.
  return /점심|저녁|오전|오후|라스트\s*오더|마지막\s*주문|웨이팅|대기|접수|재개|다시\s*(?:문|영업)|정상\s*영업|제외|예외|변경|취소|미정|예정|(?:\d{1,2}\s*시|\d{1,2}:\d{2})\s*부터|\bL\.?\s*O\.?\b/i.test(message);
}

function hasConflictingClock(fact: PublicationFact): boolean {
  const times = [...fact.message.matchAll(/(\d{1,2})(?:\s*시(?:\s*(\d{1,2})\s*분)?|:(\d{2}))/g)]
    .map((match) => `${match[1].padStart(2, "0")}:${(match[2] ?? match[3] ?? "00").padStart(2, "0")}`);
  return times.some((time) => fact.time_meaning !== "closing" || time !== fact.ends_at);
}

function shopTopic(name: string): string {
  const last = name.trim().at(-1)?.charCodeAt(0) ?? 0;
  // Non-Hangul names have pronunciation-dependent particles. Do not guess them.
  if (last < 0xac00 || last > 0xd7a3) throw new Error("operating_notice_copy_review_required");
  return name + ((last - 0xac00) % 28 === 0 ? "는" : "은");
}

function dateRange(start: string, end: string): string {
  const currentYear = new Intl.DateTimeFormat("en", { year: "numeric", timeZone: "Asia/Seoul" }).format(new Date());
  const includeYear = start.slice(0, 4) !== currentYear || end.slice(0, 4) !== currentYear;
  const label = (value: string) => {
    const [year, month, day] = value.split("-").map(Number);
    return `${includeYear ? `${year}년 ` : ""}${month}월 ${day}일`;
  };
  return start === end ? label(start) : `${label(start)}부터 ${label(end)}까지`;
}

function clockTime(time: string): string {
  const [hour, minute] = time.split(":").map(Number);
  return `${hour}시${minute ? ` ${minute}분` : ""}`;
}
