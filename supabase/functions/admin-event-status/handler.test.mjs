import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import test from "node:test";
import { isManageableEvent, validDate } from "../_shared/admin-event-policy.ts";

const source = stripTypeScriptTypes((await readFile(new URL("./index.ts", import.meta.url), "utf8")).replace(/^import .*;\n/gm, ""));
const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Seoul" }).format(new Date());
function harness({ allowed = true, rows = [] } = {}) {
  let handler;
  const calls = { updates: [], filters: [], rpc: [], clients: 0 };
  const query = {
    select() { return this; },
    or(value) { calls.filters.push(value); return this; },
    eq() { return this; },
    update(value) { calls.updates.push(value); return this; },
    async order() { return { data: rows, error: null }; },
    async maybeSingle() { return { data: { id: "event" }, error: null }; },
  };
  runInNewContext(source, {
    Deno: { serve: (value) => { handler = value; } },
    Response, Request, Date, Intl,
    isManageableEvent, validDate,
    isAdministrator: async () => allowed,
    createServiceClient: () => {
      calls.clients++;
      return { from: () => query, rpc: async (name, body) => { calls.rpc.push({ name, body }); return { error: null }; } };
    },
  });
  return {
    calls,
    invoke: (body) => handler(new Request("https://example.com/admin-event-status", { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json" } })),
  };
}

test("administrator authorization is retained for all mutations", async () => {
  const app = harness({ allowed: false });
  for (const action of ["list", "update", "edit"]) assert.equal((await app.invoke({ action })).status, 403);
  assert.equal(app.calls.clients, 0);
});
test("list filters old null-ended events and retains future events", async () => {
  const app = harness({ rows: [
    { id: "old", start_date: "2020-01-01", end_date: null, event_type: "store_renewal" },
    { id: "today", start_date: today, end_date: null, event_type: "limited_menu" },
    { id: "future", start_date: "2099-01-01", end_date: "2099-01-02", event_type: "popup" },
  ] });
  const response = await app.invoke({ action: "list" });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).map((event) => event.id), ["today", "future"]);
  assert.equal(app.calls.filters[0], `end_date.gte.${today},end_date.is.null`);
});
test("image-only events with empty descriptions can be edited", async () => {
  const app = harness();
  const response = await app.invoke({ action: "edit", event_id: "event", title: "Image event", description: "", event_type: "limited_menu", start_date: today, end_date: today });
  assert.equal(response.status, 200);
  assert.equal(app.calls.updates[0].description, "");
});
test("missing description cannot silently erase existing content", async () => {
  const app = harness();
  const response = await app.invoke({ action: "edit", event_id: "event", title: "Event", event_type: "limited_menu", start_date: today });
  assert.equal(response.status, 400);
  assert.equal(app.calls.updates.length, 0);
});
test("invalid cancellation never reaches the database", async () => {
  const app = harness();
  const response = await app.invoke({ action: "update", event_id: "event", status: "cancelled", scope: "custom_period", reason: "reason", start_date: "2026-10-12", end_date: "2026-10-11" });
  assert.equal(response.status, 400);
  assert.equal(app.calls.rpc.length, 0);
});
test("new menus retain their seven day duration on edit", async () => {
  const app = harness();
  const response = await app.invoke({ action: "edit", event_id: "event", title: "New menu", description: "", event_type: "new_menu", start_date: "2026-10-11", end_date: "2026-10-11" });
  assert.equal(response.status, 200);
  assert.equal(app.calls.updates[0].end_date, "2026-10-17");
});
