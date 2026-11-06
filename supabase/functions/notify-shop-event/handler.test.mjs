import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import test from "node:test";

const source = stripTypeScriptTypes(
  (await readFile(new URL("./index.ts", import.meta.url), "utf8"))
    .replace(/^import \{[\s\S]*?\} from "\.\.\/_shared\/event-notifications\.ts";\n/, ""),
);
const validPayload = {
  type: "INSERT",
  table: "shop_events",
  schema: "public",
  record: { id: "test-event", shop_id: "test-shop", title: "테스트 이벤트", event_type: "popup" },
};
const notificationTotals = { targeted: 1, sent: 1, failed: 0, unknown: 0 };

function harness({ secret = "test-webhook-secret", sendError } = {}) {
  let handler;
  const calls = { clients: 0, eventTypes: [], notifications: [], errors: [] };
  const client = { testClient: true };
  runInNewContext(source, {
    Deno: {
      env: { get: (name) => name === "WEBHOOK_SECRET" ? secret : undefined },
      serve: (value) => { handler = value; },
    },
    Response, Error,
    console: { error: (error) => calls.errors.push(error) },
    assertKnownEventType: (eventType) => {
      calls.eventTypes.push(eventType);
      if (eventType !== "popup") throw new Error(`Unsupported event_type: ${eventType}`);
    },
    createServiceClient: () => {
      calls.clients++;
      return client;
    },
    sendEventNotifications: async (...args) => {
      calls.notifications.push(args);
      if (sendError) throw sendError;
      return notificationTotals;
    },
  });
  const invokeRaw = (body, requestSecret = "test-webhook-secret") => handler(new Request(
    "https://example.com/notify-shop-event",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(requestSecret === null ? {} : { "x-webhook-secret": requestSecret }),
      },
      body,
    },
  ));
  return {
    calls, client, handler, invokeRaw,
    invoke: (body, requestSecret) => invokeRaw(JSON.stringify(body), requestSecret),
  };
}

function assertNoNotification(app) {
  assert.equal(app.calls.clients, 0);
  assert.equal(app.calls.notifications.length, 0);
  assert.equal(app.calls.eventTypes.length, 0);
}

test("웹훅 비밀키 설정이 없으면 본문을 읽지 않고 503을 반환한다", async () => {
  const app = harness({ secret: "" });
  const response = await app.handler({
    json: () => { throw new Error("본문을 읽으면 안 된다"); },
  });
  assert.equal(response.status, 503);
  assertNoNotification(app);
});

for (const secret of [null, "wrong-secret"]) {
  test(`웹훅 인증 실패(${secret ?? "누락"})는 잘못된 JSON보다 먼저 401로 거절한다`, async () => {
    const app = harness();
    const response = await app.invokeRaw("{", secret);
    assert.equal(response.status, 401);
    assertNoNotification(app);
  });
}

test("인증 성공 후 JSON 파싱에 실패하면 400을 반환하고 발송하지 않는다", async () => {
  const app = harness();
  const response = await app.invokeRaw("{");
  assert.equal(response.status, 400);
  assert.equal(await response.text(), "Invalid JSON");
  assertNoNotification(app);
});

for (const [name, payload] of [
  ["null", null], ["배열", []], ["문자열", "payload"], ["숫자", 1], ["불리언", true],
]) {
  test(`객체가 아닌 본문(${name})은 400으로 거절한다`, async () => {
    const app = harness();
    assert.equal((await app.invoke(payload)).status, 400);
    assertNoNotification(app);
  });
}

for (const [name, patch] of [
  ["다른 스키마", { schema: "private" }],
  ["스키마 누락", { schema: undefined }],
  ["스키마 null", { schema: null }],
  ["다른 테이블", { table: "other_events" }],
  ["테이블 누락", { table: undefined }],
  ["UPDATE", { type: "UPDATE" }],
  ["DELETE", { type: "DELETE" }],
  ["동작 누락", { type: undefined }],
]) {
  test(`처리 대상이 아닌 웹훅(${name})은 202로 무시하고 발송하지 않는다`, async () => {
    const app = harness();
    const response = await app.invoke({ ...validPayload, ...patch });
    assert.equal(response.status, 202);
    assert.equal(await response.text(), "Ignored");
    assertNoNotification(app);
  });
}

for (const [name, record] of [
  ["누락", undefined], ["null", null], ["배열", []], ["문자열", "record"],
  ["이벤트 종류 누락", {}], ["이벤트 종류 null", { event_type: null }],
]) {
  test(`잘못된 이벤트 레코드(${name})는 400으로 거절한다`, async () => {
    const app = harness();
    assert.equal((await app.invoke({ ...validPayload, record })).status, 400);
    assertNoNotification(app);
  });
}

test("정상 public.shop_events INSERT는 기존 알림 함수로 한 번만 전달한다", async () => {
  const app = harness();
  const response = await app.invoke(validPayload);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), notificationTotals);
  assert.equal(app.calls.clients, 1);
  assert.deepEqual(app.calls.eventTypes, ["popup"]);
  assert.equal(app.calls.notifications.length, 1);
  assert.deepEqual(app.calls.notifications[0], [app.client, validPayload.record, "new_event"]);
});

test("알 수 없는 이벤트 종류는 기존 검증 오류 계약을 유지하고 발송하지 않는다", async () => {
  const app = harness();
  const response = await app.invoke({
    ...validPayload, record: { ...validPayload.record, event_type: "unknown" },
  });
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: "Unsupported event_type: unknown" });
  assert.equal(app.calls.clients, 0);
  assert.equal(app.calls.notifications.length, 0);
});

test("알림 처리 자체의 실패는 기존 500 오류 계약을 유지한다", async () => {
  const app = harness({ sendError: new Error("Notification failed") });
  const response = await app.invoke(validPayload);
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: "Notification failed" });
  assert.equal(app.calls.notifications.length, 1);
});
