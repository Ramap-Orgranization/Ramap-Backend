import assert from "node:assert/strict";
import test from "node:test";
import { dispatchPublicationDeliveries, publicationTransportEnabled, sendFcmPayload } from "./push-delivery.ts";
import { claim, fact, eventFact } from "./notification-fixtures.mjs";
function harness({ prepared = claim(), providerResult = { status: "sent", provider_id: "fake-receipt" }, completionError = false, throwProvider = false } = {}) {
  const calls = [], sends = [];
  const client = { async rpc(name, args) { calls.push({ name, args }); return { data: name === "claim_notification_deliveries" ? [claim()] : name === "prepare_notification_delivery" ? prepared : !completionError, error: completionError && name === "complete_notification_delivery" ? new Error("lost acknowledgement") : null }; } };
  const provider = { async send(target, payload) { sends.push({ target, payload }); if (throwProvider) throw new Error("timeout"); return providerResult; } };
  return { client, provider, calls, sends };
}
test("신규 전송 스위치는 기본 OFF이고 DB나 provider를 호출하지 않는다", async () => {
  const app = harness();
  for (const value of [undefined, "false", "TRUE", "1"]) assert.equal(publicationTransportEnabled(value), false);
  assert.equal((await dispatchPublicationDeliveries(app.client, app.provider, false)).disabled, true);
  assert.equal(app.calls.length, 0); assert.equal(app.sends.length, 0);
});
test("전송 직전 취소 구독 변경 기기 소유권 변경은 prepare 결과로 차단한다", async () => {
  const app = harness({ prepared: null });
  assert.equal((await dispatchPublicationDeliveries(app.client, app.provider, true)).skipped, 1);
  assert.equal(app.sends.length, 0);
});
test("claim 뒤 prepare의 최신 사실과 기기 정보만 provider에 전달한다", async () => {
  const app = harness({ prepared: claim({ registration_identifier: "current-token", facts: [eventFact()], supported_protocol_version: 0 }) });
  assert.equal((await dispatchPublicationDeliveries(app.client, app.provider, true)).sent, 1);
  assert.equal(app.sends[0].target.identifier, "current-token");
  assert.equal(app.sends[0].payload.notification.body.includes("임시휴무"), false);
  assert.deepEqual(app.calls.map(({ name }) => name), ["claim_notification_deliveries", "prepare_notification_delivery", "complete_notification_delivery"]);
});
test("provider timeout과 완료 기록 실패는 자동 재전송하지 않는다", async () => {
  const timeout = harness({ throwProvider: true });
  assert.equal((await dispatchPublicationDeliveries(timeout.client, timeout.provider, true)).unknown, 1);
  assert.equal(timeout.sends.length, 1);
  assert.equal(timeout.calls.at(-1).args.p_status, "unknown");
  const completion = harness({ completionError: true });
  assert.equal((await dispatchPublicationDeliveries(completion.client, completion.provider, true)).unknown, 1);
  assert.equal(completion.sends.length, 1);
  assert.equal(completion.calls.length, 3);
});
test("FCM token과 fid 대상 및 기존 sound 필드를 보존하고 전송은 fake로 검증한다", async () => {
  for (const target_type of ["token", "fid"]) {
    const result = await sendFcmPayload("ramap-project", "fake-access", { identifier: "fake-target", target_type }, { notification: { title: "제목", body: "본문" }, data: { deep_link: "legacy" } }, async (_url, options) => {
      const body = JSON.parse(options.body);
      assert.equal(body.message[target_type], "fake-target");
      assert.equal(body.message.android.notification.sound, "default");
      assert.equal(body.message.apns.payload.aps.sound, "default");
      assert.deepEqual(body.message.apns.headers, { "apns-push-type": "alert", "apns-priority": "10" });
      assert.deepEqual(body.message.apns.payload.aps.alert, { title: "제목", body: "본문" });
      assert.deepEqual(body.message.apns.payload.aps.alert, body.message.notification);
      return Response.json({ name: "fake-message" });
    });
    assert.equal(result.status, "sent");
  }
});
test("FCM 서버 오류와 전송 예외는 unknown으로 종료한다", async () => {
  const target = { identifier: "fake", target_type: "token" }, payload = { notification: { title: "a", body: "b" }, data: {} };
  assert.equal((await sendFcmPayload("ramap-project", "fake", target, payload, async () => new Response("error", { status: 503 }))).status, "unknown");
  assert.equal((await sendFcmPayload("ramap-project", "fake", target, payload, async () => { throw new Error("offline"); })).status, "unknown");
});
test("DB OFF does not obtain credentials and missing credentials never prepare sending", async () => {
  let factories = 0;
  const empty = { async rpc(name) { assert.equal(name, 'claim_notification_deliveries'); return { data: [], error: null }; } };
  await dispatchPublicationDeliveries(empty, async () => { factories++; throw new Error('missing'); }, true);
  assert.equal(factories, 0);
  const app = harness();
  await assert.rejects(dispatchPublicationDeliveries(app.client, async () => { throw new Error('missing'); }, true), /missing/);
  assert.deepEqual(app.calls.map(c => c.name), ['claim_notification_deliveries']);
  assert.equal(app.sends.length, 0);
});
test('invalid prepared payload is failed without provider invocation', async () => {
  const app = harness({ prepared: claim({ facts: [fact({ message: 'x'.repeat(5000) })] }) });
  assert.equal((await dispatchPublicationDeliveries(app.client, app.provider, true)).failed, 1);
  assert.equal(app.sends.length, 0);
  assert.equal(app.calls.at(-1).args.p_status, 'failed');
});
test('legacy HTTP 5xx/408 stay failed while new publication responses stay unknown', async () => {
  const target = { identifier: 'fake', target_type: 'token' };
  const payload = { notification: { title: 'a', body: 'b' }, data: {} };
  for (const status of [500, 503, 408]) {
    const request = async () => new Response('failure', { status });
    assert.equal((await sendFcmPayload('ramap-project', 'fake', target, payload, request, 'legacy')).status, 'failed');
    assert.equal((await sendFcmPayload('ramap-project', 'fake', target, payload, request)).status, 'unknown');
  }
  for (const mode of ['legacy', 'conservative']) {
    assert.equal((await sendFcmPayload('ramap-project', 'fake', target, payload, async () => { throw new Error('network timeout'); }, mode)).status, 'unknown');
  }
});
test('legacy event adapter explicitly retains HTTP failure policy without changing payload', async () => {
  const { readFile } = await import('node:fs/promises');
  const { stripTypeScriptTypes } = await import('node:module');
  const { runInNewContext } = await import('node:vm');
  const source = await readFile(new URL('./event-notifications.ts', import.meta.url), 'utf8');
  const adapter = source.slice(source.indexOf('async function sendMessage('), source.indexOf('async function finishDelivery('));
  const event = { id: 'event-id', shop_id: 'shop-id', title: 'original title', event_type: 'popup' };
  for (const status of [503, 408]) {
    const context = { sendFcmPayload, Error, notificationTitle: () => 'original title', fetch: async (_url, options) => {
      const message = JSON.parse(options.body).message;
      assert.equal(message.data.notification_type, 'day_before');
      assert.equal(message.data.deep_link, 'ramap://notification/event?event_id=event-id');
      return new Response('failure', { status });
    } };
    runInNewContext(stripTypeScriptTypes(adapter) + '\nglobalThis.send = sendMessage;', context);
    const result = await context.send('ramap-project', 'fake', { identifier: 'fake', target_type: 'token' }, event, 'day_before');
    assert.equal(result.ok, false);
    assert.equal(result.error, `provider_${status}`);
  }
});
test('actual legacy sender persists HTTP failures as failed and network exceptions as unknown', async () => {
  const { readFile } = await import('node:fs/promises');
  const { stripTypeScriptTypes } = await import('node:module');
  const { runInNewContext } = await import('node:vm');
  const source = (await readFile(new URL('./event-notifications.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
  for (const outcome of [503, 408, 'network']) {
    const updates = []; let requests = 0;
    const client = {
      async rpc(name) { assert.equal(name, 'claim_event_notification_delivery'); return { data: true, error: null }; },
      from(table) {
        const query = {
          select() { return this; }, eq() { return this; }, not() { return this; }, in() { return this; },
          update(value) { updates.push({ table, value }); return this; }, match() { return this; },
          then(resolve, reject) {
            const data = table === 'shop_event_notification_subscriptions' ? [{ user_id: 'user' }] : table === 'push_registrations' ? [{ user_id: 'user', identifier: 'fake', target_type: 'token' }] : [];
            return Promise.resolve({ data, error: null }).then(resolve, reject);
          },
        }; return query;
      },
    };
    const context = {
      sendFcmPayload, Error, Date,
      Deno: { env: { get: () => JSON.stringify({ project_id: 'ramap-project', client_email: 'fake', private_key: 'fake' }) } },
      JWT: class { async authorize() { return { access_token: 'fake' }; } },
      fetch: async () => { requests++; if (outcome === 'network') throw new Error('fake timeout'); return new Response('failure', { status: outcome }); },
    };
    runInNewContext(stripTypeScriptTypes(source) + '\nglobalThis.send = sendEventNotifications;', context);
    const totals = await context.send(client, { id: 'event', shop_id: 'shop', title: 'original', event_type: 'popup' }, 'day_before');
    const status = outcome === 'network' ? 'unknown' : 'failed';
    assert.equal(totals[status], 1); assert.equal(requests, 1);
    assert.equal(updates.length, 1); assert.equal(updates[0].table, 'event_notification_deliveries');
    assert.equal(updates[0].value.status, status);
  }
});
