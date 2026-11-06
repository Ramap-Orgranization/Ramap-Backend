import type { SupabaseClient } from "npm:@supabase/supabase-js@2.55.0";

type Environment = { get(name: string): string | undefined };

export function mediaStorage(client: SupabaseClient, environment: Environment = Deno.env) {
  const base = environment.get("MEDIA_API_URL")?.replace(/\/$/, "");
  const serviceKey = environment.get("SUPABASE_SERVICE_ROLE_KEY");
  const version = /^[a-f0-9]{32}$/.test(environment.get("R2_ACCOUNT_ID") ?? "") ? "v2/" : "";
  async function call(action: string, body: unknown) {
    if (!base || !serviceKey || new URL(base).protocol !== "https:") throw new Error("Media gateway is unavailable");
    const response = await fetch(`${base}/internal/${version}${action}`, {
      method: "POST", headers: { Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(body), signal: AbortSignal.timeout(30_000), redirect: "error",
    });
    if (!response.ok) throw new Error("Media request failed");
    return response.json();
  }
  return {
    async copy(sourceBucket: string, sourcePath: string, bucket: string, path: string) {
      if (base) return await call("copy", { source: { bucket: sourceBucket, path: sourcePath }, bucket, path });
      const { data, error } = await client.storage.from(sourceBucket).download(sourcePath);
      if (error || !data) throw new Error("Media source unavailable");
      const { error: uploadError } = await client.storage.from(bucket).upload(path, await data.arrayBuffer(), { contentType: data.type, upsert: false });
      if (uploadError) throw uploadError;
    },
    from(bucket: string) {
      const legacy = client.storage.from(bucket);
      return {
        async upload(path: string, bytes: ArrayBuffer | Uint8Array, options: { contentType: string; upsert?: boolean }) {
          if (!base) return legacy.upload(path, bytes, options);
          try {
            const prepared = await call("prepare", { bucket, path, byte_size: bytes.byteLength, content_type: options.contentType });
            if (prepared.provider === "supabase") return legacy.upload(path, bytes, options);
            if (!prepared.ready) {
              const target = new URL(prepared.url);
              const account = environment.get("R2_ACCOUNT_ID") ?? "";
              const r2 = prepared.provider === "r2" && /^[a-f0-9]{32}$/.test(account)
                && target.hostname === `${account}.r2.cloudflarestorage.com`
                && target.pathname === `/${environment.get("R2_PRIVATE_BUCKET")}/pending/${prepared.id}`
                && target.searchParams.get("X-Amz-Algorithm") === "AWS4-HMAC-SHA256" && !!target.searchParams.get("X-Amz-Signature");
              if (target.protocol !== "https:" || target.port || target.username || target.password || target.hash || !r2) throw new Error("Invalid media target");
              const headers = new Headers({ "Content-Type": options.contentType, "If-None-Match": "*" });
              const uploadBytes = bytes instanceof ArrayBuffer ? bytes : new Uint8Array(bytes).buffer;
              const response = await fetch(target, { method: "PUT", body: uploadBytes, headers, redirect: "error", signal: AbortSignal.timeout(30_000) });
              if (!response.ok && response.status !== 412) throw new Error("Media upload failed");
              await call("finalize", { id: prepared.id });
            }
            return { data: { path }, error: null };
          } catch { return { data: null, error: new Error("Media upload failed") }; }
        },
        async remove(paths: string[]) {
          if (!base) return legacy.remove(paths);
          try {
            for (const path of paths) await call("delete", { bucket, path });
            return { data: [], error: null };
          } catch { return { data: null, error: new Error("Media cleanup failed") }; }
        },
        async createSignedUrl(path: string, expiresIn: number) {
          if (!base) return legacy.createSignedUrl(path, expiresIn);
          try {
            const rows = await call("resolve", { images: [{ bucket, path }] });
            const match = rows.find((row: { bucket: string; path: string; url?: string }) => row.bucket === bucket && row.path === path);
            if (!match?.url) throw new Error("Media unavailable");
            return { data: { signedUrl: match.url as string }, error: null };
          } catch { return { data: null, error: new Error("Media unavailable") }; }
        },
      };
    },
  };
}
