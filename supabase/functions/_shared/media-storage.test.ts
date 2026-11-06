import assert from "node:assert/strict";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.55.0";
import { mediaStorage } from "./media-storage.ts";

const environment = { get: (name: string) => ({ MEDIA_API_URL: "https://media.invalid", R2_ACCOUNT_ID: "a".repeat(32), R2_PRIVATE_BUCKET: "r2-private", SUPABASE_SERVICE_ROLE_KEY: "server-secret" })[name as "MEDIA_API_URL"] };
const client = { storage: { from: () => ({ upload: () => assert.fail("설정된 API 실패를 legacy 업로드로 우회함") }) } } as unknown as SupabaseClient;

Deno.test("Edge 사진 업로드는 서버 키를 제어 API에만 보내고 실제 바이트를 R2에 직접 전송한다", async () => {
  const original = globalThis.fetch;
  const calls: Request[] = [];
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    calls.push(request);
    if (request.url.endsWith("/internal/v2/prepare")) return Response.json({ provider: "r2", id: "upload", ready: false, url: "https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com/r2-private/pending/upload?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=signed" });
    if (request.url.includes("r2.cloudflarestorage.com")) {
      assert.equal(request.headers.get("Authorization"), null);
      assert.equal(request.headers.get("If-None-Match"), "*");
      assert.deepEqual(new Uint8Array(await request.arrayBuffer()), new Uint8Array([1, 2, 3]));
      return new Response(null, { status: 200 });
    }
    assert.ok(request.url.endsWith("/internal/v2/finalize"));
    return Response.json({ ready: true });
  };
  try {
    const result = await mediaStorage(client, environment).from("event-images").upload("event.jpg", new Uint8Array([1, 2, 3]), { contentType: "image/jpeg" });
    assert.equal(result.error, null);
    assert.equal(calls.length, 3);
    assert.equal(calls[0].headers.get("Authorization"), "Bearer server-secret");
    assert.equal(calls[2].headers.get("Authorization"), "Bearer server-secret");
  } finally { globalThis.fetch = original; }
});

Deno.test("Edge API 실패와 위조된 업로드 URL에는 사진을 보내지 않는다", async () => {
  const original = globalThis.fetch;
  try {
    for (const response of [new Response(null, { status: 503 }), Response.json({ provider: "r2", id: "upload", url: "https://other.invalid/private/pending/upload?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=signed" })]) {
      let count = 0;
      globalThis.fetch = async () => { count++; return response; };
      const result = await mediaStorage(client, environment).from("event-images").upload("event.jpg", new Uint8Array([1]), { contentType: "image/jpeg" });
      assert.ok(result.error);
      assert.equal(count, 1);
    }
  } finally { globalThis.fetch = original; }
});

Deno.test("제보 사진 복사는 Edge로 다운로드하지 않고 사진 서버에 논리 경로를 전달한다", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    assert.equal(request.url, "https://media.invalid/internal/v2/copy");
    assert.deepEqual(await request.json(), { source: { bucket: "news-report-evidence", path: "evidence.jpg" }, bucket: "event-images", path: "event.jpg" });
    return Response.json({ copied: true });
  };
  try {
    await mediaStorage(client, environment).copy("news-report-evidence", "evidence.jpg", "event-images", "event.jpg");
  } finally { globalThis.fetch = original; }
});

Deno.test("Edge R2 전송도 신뢰한 계정의 임시 객체만 허용하고 서버 키를 보내지 않는다", async () => {
  const original = globalThis.fetch;
  const account = "a".repeat(32);
  const r2env = { get: (name: string) => name === "R2_ACCOUNT_ID" ? account : name === "R2_PRIVATE_BUCKET" ? "r2-private" : environment.get(name) };
  let uploads = 0;
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    if (request.url.endsWith("/prepare")) return Response.json({ provider: "r2", id: "upload", url: `https://${account}.r2.cloudflarestorage.com/r2-private/pending/upload?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=signed` });
    if (request.url.includes("cloudflarestorage.com")) {
      uploads++;
      assert.equal(request.headers.get("Authorization"), null);
      assert.equal(request.headers.get("If-None-Match"), "*");
      return new Response(null, { status: 200 });
    }
    return Response.json({ ready: true });
  };
  try {
    assert.equal((await mediaStorage(client, r2env).from("event-images").upload("event.jpg", new Uint8Array([1]), { contentType: "image/jpeg" })).error, null);
    assert.equal(uploads, 1);
  } finally { globalThis.fetch = original; }
});
