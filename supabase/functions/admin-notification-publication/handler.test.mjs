import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { runInNewContext } from 'node:vm';
import test from 'node:test';
const source = stripTypeScriptTypes((await readFile(new URL('./index.ts', import.meta.url), 'utf8')).replace(/^import .*;\n/gm, ''));
function harness(admin = true, error = null) {
  let handler, calls = 0;
  runInNewContext(source, { Deno: { serve(fn) { handler = fn; } }, Response, TextEncoder, Error,
    isAdministrator: async () => admin, createServiceClient: () => ({}),
    publicationCommand: async () => { calls++; if (error) throw error; return { revision: 1 }; } });
  return { invoke: (body = '{}', method = 'POST') => handler(new Request('https://example.com', { method, ...(method === 'POST' ? { body } : {}) })), calls: () => calls };
}
test('administrator authentication and POST required before commands', async () => {
  const app = harness(false); assert.equal((await app.invoke()).status, 403); assert.equal(app.calls(), 0);
  assert.equal((await harness().invoke('{}', 'GET')).status, 405);
});
test('malformed and oversized payload never invoke command', async () => {
  const app = harness(); assert.equal((await app.invoke('{')).status, 422);
  assert.equal((await app.invoke('x'.repeat(96001))).status, 413); assert.equal(app.calls(), 0);
});
test('revision conflict is actionable and successful response returns snapshot', async () => {
  assert.equal((await harness(true, new Error('revision_mismatch')).invoke()).status, 409);
  assert.deepEqual(await (await harness().invoke()).json(), { revision: 1 });
});
