import { isAdministrator } from "../_shared/admin-auth.ts";

Deno.serve(async (request) => {
  if (!await isAdministrator(request)) return Response.json({ code: "administrator_required" }, { status: 403 });
  return Response.json({ code: "operating_notice_action_retired" }, { status: 410 });
});
