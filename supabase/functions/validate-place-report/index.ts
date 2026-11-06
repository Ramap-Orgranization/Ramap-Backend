import { createPlaceValidationHandler } from "./handler.ts";

Deno.serve(createPlaceValidationHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
}));
