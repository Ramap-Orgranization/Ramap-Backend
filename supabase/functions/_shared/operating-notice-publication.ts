import { previewPublication, validatePublicationDocument } from "./notification-publication.ts";
import type { RpcClient } from "./notification-publication.ts";

export async function publishPendingOperatingNotices(client: RpcClient, limit: number) {
  const totals = { published: 0, skipped: 0, failed: 0 };
  const pending = await client.rpc("fetch_pending_operating_notice_publications", { p_limit: limit });
  if (pending.error) throw pending.error;
  for (const item of pending.data ?? []) {
    try {
      if (item.document !== null) previewPublication(validatePublicationDocument(item.document));
      const result = await client.rpc("publish_operating_notice_notification", { p_notice_id: item.notice_id, p_document: item.document });
      if (result.error) throw result.error;
      if (result.data?.published) totals.published++;
      else totals.skipped++;
    } catch (error) {
      const message = error instanceof Error ? error.message : String((error as { message?: unknown })?.message ?? "publication_failed");
      const code = /^[a-z0-9_]+$/.test(message) ? message : "publication_failed";
      const recorded = await client.rpc("record_operating_notice_publication_failure", { p_notice_id: item.notice_id, p_error: code });
      if (recorded.error) throw recorded.error;
      totals.failed++;
    }
  }
  return totals;
}
