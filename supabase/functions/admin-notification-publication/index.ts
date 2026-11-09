import { isAdministrator } from "../_shared/admin-auth.ts";
import { createServiceClient } from "../_shared/event-notifications.ts";
import { publicationCommand } from "../_shared/notification-publication.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ code: "method_not_allowed" }, { status: 405 });
  if (!await isAdministrator(request)) return Response.json({ code: "administrator_required" }, { status: 403 });
  const body = await request.text();
  if (new TextEncoder().encode(body).length > 96_000) return Response.json({ code: "payload_too_large" }, { status: 413 });
  try {
    const result = await publicationCommand(createServiceClient(), JSON.parse(body));
    return Response.json(result);
  } catch (error) {
    const code = error instanceof Error ? error.message : String((error as { message?: unknown })?.message ?? "publication_failed");
    const status = /revision|idempotency|already|split_required|not_ready|explicit_correction_required/.test(code) ? 409 : 422;
    return Response.json({ code: /^[a-z0-9_]+$/.test(code) ? code : "publication_failed" }, { status });
  }
});
