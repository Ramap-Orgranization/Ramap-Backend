import assert from "node:assert/strict";
import test, { afterEach, beforeEach } from "node:test";

import { isAdministrator, isAdministratorEmail } from "./admin-auth.ts";

const defaults = {
  ADMIN_EMAIL: "primary@example.com",
  ADMIN_ADDITIONAL_EMAILS: " second@example.com, third@example.com ",
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_ANON_KEY: "test-anon-key",
};
let values;
const originalFetch = globalThis.fetch;
const user = {
  id: "00000000-0000-4000-8000-000000000001",
  email: "third@example.com",
  email_confirmed_at: "2026-10-13T00:00:00Z",
  is_anonymous: false,
};
const request = () => new Request("https://example.com", {
  headers: { Authorization: "Bearer user-token" },
});

beforeEach(() => { values = { ...defaults }; });
afterEach(() => { globalThis.fetch = originalFetch; });

globalThis.Deno = { env: { get: (name) => values[name] } };

test("accepts the primary and additional administrator emails", () => {
  assert.equal(isAdministratorEmail("primary@example.com"), true);
  assert.equal(isAdministratorEmail("THIRD@EXAMPLE.COM"), true);
  assert.equal(isAdministratorEmail("second@example.com"), true);
  assert.equal(isAdministratorEmail("other@example.com"), false);
  assert.equal(isAdministratorEmail(""), false);
});

test("never grants the former fallback email without explicit configuration", async () => {
  delete values.ADMIN_EMAIL;
  delete values.ADMIN_ADDITIONAL_EMAILS;
  assert.equal(isAdministratorEmail("uni070@naver.com"), false);
  globalThis.fetch = async () => Response.json({ ...user, email: "uni070@naver.com" });
  assert.equal(await isAdministrator(request()), false);
});

test("empty configuration denies access and explicit additional-only configuration remains valid", () => {
  values.ADMIN_EMAIL = " ";
  values.ADMIN_ADDITIONAL_EMAILS = " , , ";
  for (const value of [null, undefined, "", " ", "primary@example.com", "uni070@naver.com"]) {
    assert.equal(isAdministratorEmail(value), false);
  }
  values.ADMIN_ADDITIONAL_EMAILS = " third@example.com ";
  assert.equal(isAdministratorEmail("THIRD@EXAMPLE.COM"), true);
  assert.equal(isAdministratorEmail("primary@example.com"), false);
});

test("requires a confirmed current Auth identity and forwards only the bearer token to Auth", async () => {
  globalThis.fetch = async (url, options) => {
    assert.equal(url, "https://example.supabase.co/auth/v1/user");
    assert.equal(options.headers.apikey, "test-anon-key");
    assert.equal(options.headers.Authorization, "Bearer user-token");
    return Response.json(user);
  };
  assert.equal(await isAdministrator(request()), true);
  globalThis.fetch = async () => Response.json({ ...user, email: "other@example.com" });
  assert.equal(await isAdministrator(request()), false);
});

test("unconfirmed, anonymous and missing identities cannot acquire administrator access", async () => {
  for (const override of [
    { email_confirmed_at: null }, { email_confirmed_at: "" },
    { id: null }, { id: "" }, { is_anonymous: true }, { email: null },
  ]) {
    globalThis.fetch = async () => Response.json({ ...user, ...override });
    assert.equal(await isAdministrator(request()), false);
  }
});

test("user metadata, request payload and JWT email claims cannot replace the Auth identity", async () => {
  globalThis.fetch = async () => Response.json({
    ...user,
    email: "other@example.com",
    user_metadata: { email: "third@example.com", is_admin: true, role: "admin" },
  });
  const claimedToken = `e30.${Buffer.from(JSON.stringify({ email: "third@example.com", role: "admin" })).toString("base64url")}.signature`;
  assert.equal(await isAdministrator(new Request("https://example.com", {
    method: "POST",
    headers: { Authorization: `Bearer ${claimedToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ email: "third@example.com", is_admin: true }),
  })), false);
});

test("missing credentials are denied without calling Auth", async () => {
  globalThis.fetch = async () => { throw new Error("Auth must not be called"); };
  assert.equal(await isAdministrator(new Request("https://example.com")), false);
  assert.equal(await isAdministrator(new Request("https://example.com", {
    headers: { Authorization: "Basic user-token" },
  })), false);
  delete values.SUPABASE_URL;
  assert.equal(await isAdministrator(request()), false);
  values.SUPABASE_URL = defaults.SUPABASE_URL;
  delete values.SUPABASE_ANON_KEY;
  assert.equal(await isAdministrator(request()), false);
});

test("Auth rejection, failures and invalid JSON fail closed", async () => {
  for (const status of [401, 403, 500]) {
    globalThis.fetch = async () => Response.json(user, { status });
    assert.equal(await isAdministrator(request()), false);
  }
  globalThis.fetch = async () => { throw new Error("network failure"); };
  assert.equal(await isAdministrator(request()), false);
  globalThis.fetch = async () => new Response("not JSON", { status: 200 });
  assert.equal(await isAdministrator(request()), false);
  globalThis.fetch = async () => Response.json(null);
  assert.equal(await isAdministrator(request()), false);
});
