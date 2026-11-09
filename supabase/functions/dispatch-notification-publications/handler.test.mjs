import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import test from 'node:test';
import { publicationTransportEnabled } from '../_shared/push-delivery.ts';
const source = stripTypeScriptTypes((await readFile(new URL('./index.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, ''));
function harness(env = {}, failure = false) {
  let handler; const calls = [];
  runInNewContext(source, { Deno: { serve(fn) { handler = fn; }, env: { get: name => env[name] } }, Response,
    publicationTransportEnabled, configuredPushProvider: async () => { calls.push('credentials'); return {}; },
    createServiceClient: () => { calls.push('db'); return {}; },
    publishPendingOperatingNotices: async () => { calls.push('publish-notices'); return { published: 1, failed: 0, skipped: 0 }; },
    dispatchPublicationDeliveries: async (_client, provider) => { calls.push('dispatch'); if (failure) throw Error('missing'); await provider(); return { sent: 1 }; } });
  return { calls, invoke: (body = '{"limit":20}', secret = 'fake') => handler(new Request('https://example.com', { method: 'POST', body, headers: { 'x-notification-dispatch-secret': secret } })) };
}
test('missing secret and incorrect secret fail closed', async () => {
  const missing = harness(); assert.equal((await missing.invoke()).status, 503); assert.deepEqual(missing.calls, []);
  const wrong = harness({ NOTIFICATION_DISPATCH_SECRET: 'other' }); assert.equal((await wrong.invoke()).status, 401); assert.deepEqual(wrong.calls, []);
});
test('default OFF does not create clients or credentials even for malformed body', async () => {
  const app = harness({ NOTIFICATION_DISPATCH_SECRET: 'fake' }); assert.equal((await app.invoke('{')).status, 200); assert.deepEqual(app.calls, []);
});
test('bounded batch validation and configured dispatcher failure', async () => {
  const env = { NOTIFICATION_DISPATCH_SECRET: 'fake', NOTIFICATION_PUBLICATION_TRANSPORT_ENABLED: 'true' };
  const invalid = harness(env); assert.equal((await invalid.invoke('{"limit":101}')).status, 400); assert.deepEqual(invalid.calls, []);
  assert.equal((await harness(env, true).invoke()).status, 503);
  const ok = harness(env); assert.equal((await ok.invoke()).status, 200); assert.deepEqual(ok.calls, ['db', 'publish-notices', 'dispatch', 'credentials']);
});
