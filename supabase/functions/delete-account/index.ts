import { createClient } from "npm:@supabase/supabase-js@2.55.0";
import { createServiceClient } from "../_shared/event-notifications.ts";
import { handleAuthenticatedDeletion } from "./handler.ts";

Deno.serve(async (request) => {
    if (request.method !== "POST") return Response.json({ code: "method_not_allowed" }, { status: 405 });
    try {
        const authorization = request.headers.get("authorization");
        const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();
        const url = Deno.env.get("SUPABASE_URL");
        const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
        if (!token || !url || !anonKey) return Response.json({ code: "authentication_required" }, { status: 401 });

        const accountClient = createClient(url, anonKey, {
            auth: { persistSession: false, autoRefreshToken: false },
            global: { headers: { Authorization: `Bearer ${token}` } },
        });
        const { data, error } = await accountClient.auth.getUser(token);
        if (error || !data.user) return Response.json({ code: "authentication_required" }, { status: 401 });

        const serviceClient = createServiceClient();
        const mediaUrl = Deno.env.get("MEDIA_API_URL");
        const cleanupMedia = async () => {
            if (!mediaUrl) {
                const { data: count, error } = await serviceClient.rpc("account_has_external_media", { p_user_id: data.user.id });
                return !error && count === false;
            }
            const response = await fetch(`${mediaUrl.replace(/\/$/, "")}/v1/account/cleanup`, {
                method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
                body: "{}", signal: AbortSignal.timeout(45_000), redirect: "error",
            }).catch(() => null);
            return response?.ok === true;
        };
        const result = await handleAuthenticatedDeletion(request.method, data.user.id, accountClient, Object.assign(serviceClient, { cleanupMedia }));
        return Response.json(result.body, { status: result.status });
    } catch {
        return Response.json({ code: "account_deletion_failed" }, { status: 503 });
    }
});
