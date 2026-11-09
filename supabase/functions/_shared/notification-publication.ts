import { assertCompatibleFacts, buildPublicationPayload, UUID, validOfficialUrl, validateFact } from "./notification-payload.ts";
import type { PublicationFact } from "./notification-payload.ts";

export type PublicationDocument = {
  source: { url: string; raw_text: string; official_verified: boolean };
  facts: PublicationFact[];
};
export type PublicationSnapshot = PublicationDocument & {
  announcement_id: string; revision: number; status: string; kind: string;
};
export type RpcClient = { rpc(name: string, parameters: Record<string, unknown>): PromiseLike<{ data: any; error: any }> };
const PREVIEW_ID = "00000000-0000-4000-8000-000000000001";

export function validatePublicationDocument(value: unknown): PublicationDocument {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_document");
  const document = value as PublicationDocument;
  const source = document.source;
  if (!source || !validOfficialUrl(source.url) || typeof source.raw_text !== "string" || !source.raw_text.trim()
    || source.raw_text.length > 32_000 || typeof source.official_verified !== "boolean") throw new Error("invalid_source");
  if (!Array.isArray(document.facts) || !document.facts.length || document.facts.length > 32) throw new Error("invalid_facts");
  const facts = document.facts.map((fact) => validateFact(fact, source.url));
  if (new Set(facts.map((fact) => fact.id)).size !== facts.length) throw new Error("duplicate_fact_id");
  const eventRegistrations = facts.filter((fact) => fact.registration_type === "event").map((fact) => fact.registration_id);
  if (new Set(eventRegistrations).size !== eventRegistrations.length) throw new Error("duplicate_event_fact");
  return { source: { url: source.url, raw_text: source.raw_text, official_verified: source.official_verified }, facts };
}

export function previewPublication(document: PublicationDocument, kind = "initial") {
  const verified = document.facts.filter((fact) => fact.verified && fact.certainty !== "unknown");
  assertCompatibleFacts(verified);
  const categories = [...new Set(verified.map((fact) => fact.type_id))].sort();
  if (categories.length > 10) throw new Error("too_many_preview_categories");
  const previews = [];
  for (let mask = 1; mask < 2 ** categories.length; mask++) {
    const selected = categories.filter((_, index) => (mask & (1 << index)) !== 0);
    const facts = verified.filter((fact) => selected.includes(fact.type_id));
    for (const protocol of [0, 1, 2]) {
      const payload = buildPublicationPayload({ notificationId: PREVIEW_ID, facts, protocol, sourceUrl: document.source.url, correction: kind !== "initial", cancelled: kind === "cancellation" });
      if (payload) previews.push({ selected_type_ids: selected, supported_protocol_version: protocol, payload });
    }
  }
  // A device may subscribe to only one branch of a multi-shop source.
  // Validate those payloads too; their single destination can be longer.
  for (const fact of verified) buildPublicationPayload({ notificationId: PREVIEW_ID, facts: [fact], protocol: 1, sourceUrl: document.source.url });
  return { previews, unknown_fact_ids: document.facts.filter((fact) => !fact.verified || fact.certainty === "unknown").map((fact) => fact.id) };
}

export async function publicationCommand(client: RpcClient, body: unknown) {
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("invalid_command");
  const request = body as Record<string, unknown>;
  if (!["draft", "preview", "publish", "correct", "cancel"].includes(String(request.command))) throw new Error("invalid_command");
  const initialDraft = request.command === "draft" && request.expected_revision === 0 && request.announcement_id == null;
  if (!initialDraft && (typeof request.announcement_id !== "string" || !UUID.test(request.announcement_id))) throw new Error("invalid_announcement_id");
  if (initialDraft) request.announcement_id = null;
  if (!Number.isInteger(request.expected_revision) || Number(request.expected_revision) < 0) throw new Error("invalid_revision");
  if (typeof request.idempotency_key !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(request.idempotency_key)) throw new Error("invalid_idempotency_key");
  const document = ["draft", "correct", "cancel"].includes(String(request.command)) ? validatePublicationDocument(request.document) : null;
  if (document && request.command !== "draft") previewPublication(document);
  // Preview validates the persisted revision before marking it reviewed. This
  // avoids granting publish approval to a body the administrator did not see.
  if (request.command === "preview" || request.command === "publish") {
    const { data, error } = await client.rpc("notification_publication_command", {
      p_command: "read", p_announcement_id: request.announcement_id, p_expected_revision: request.expected_revision,
      p_document: null, p_idempotency_key: request.idempotency_key,
    });
    if (error) throw error;
    const checked = validatePublicationDocument(data);
    const preview = previewPublication(checked, data.kind);
    const result = await command(client, request, null);
    return request.command === "preview" ? { ...result, ...preview } : result;
  }
  return command(client, request, document);
}

async function command(client: RpcClient, request: Record<string, unknown>, document: PublicationDocument | null) {
  const { data, error } = await client.rpc("notification_publication_command", {
    p_command: request.command, p_announcement_id: request.announcement_id, p_expected_revision: request.expected_revision,
    p_document: document, p_idempotency_key: request.idempotency_key,
  });
  if (error) throw error;
  return data;
}

export async function linkRegistration(client: RpcClient, announcementId: string, revision: number, type: string, id: string, ready: boolean) {
  const { error } = await client.rpc("link_notification_registration", {
    p_announcement_id: announcementId, p_expected_revision: revision,
    p_registration_type: type, p_registration_id: id, p_ready: ready,
  });
  if (error) throw error;
}

export function announcementLink(body: Record<string, unknown> | null): { id: string; revision: number } | null {
  if (!body || body.announcement_id == null) return null;
  if (typeof body.announcement_id !== "string" || !UUID.test(body.announcement_id)
    || !Number.isInteger(body.announcement_revision) || Number(body.announcement_revision) < 1) throw new Error("invalid_announcement_link");
  return { id: body.announcement_id, revision: Number(body.announcement_revision) };
}
