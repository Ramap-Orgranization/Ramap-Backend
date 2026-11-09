import assert from 'node:assert/strict';
import test from 'node:test';
import { publicationCommand } from './notification-publication.ts';
import { source, fact, id } from './notification-fixtures.mjs';
const document = { source, facts: [fact()] };
test('first draft forwards null identity and returns generated revision', async () => {
  const calls = [];
  const client = { async rpc(name, args) { calls.push(args); return { data: { ...document, announcement_id: id(8), revision: 1, status: 'draft' }, error: null }; } };
  const result = await publicationCommand(client, { command: 'draft', expected_revision: 0, document, idempotency_key: 'create-1' });
  assert.equal(calls[0].p_announcement_id, null);
  assert.equal(result.announcement_id, id(8)); assert.equal(result.revision, 1);
  for (const command of ['preview', 'publish', 'correct', 'cancel']) await assert.rejects(publicationCommand(client, { command, expected_revision: 0, document, idempotency_key: 'x' }), /invalid_announcement_id/);
});
test('preview and publish validate persisted revision before mutation', async () => {
  for (const command of ['preview', 'publish']) {
    const calls = [];
    const client = { async rpc(name, args) { calls.push(args.p_command); return { data: { ...document, kind: 'initial', revision: 1 }, error: null }; } };
    await publicationCommand(client, { command, announcement_id: id(8), expected_revision: 1, idempotency_key: command });
    assert.deepEqual(calls, ['read', command]);
  }
});
test('stale read and oversized persisted facts never mark preview or publish', async () => {
  const calls = [];
  const client = { async rpc(name, args) { calls.push(args.p_command); return { data: null, error: new Error('revision_mismatch') }; } };
  await assert.rejects(publicationCommand(client, { command: 'preview', announcement_id: id(8), expected_revision: 1, idempotency_key: 'x' }), /revision_mismatch/);
  assert.deepEqual(calls, ['read']);
});
test('authoritative history rejection propagates without approving removed or recategorized delivered facts', async () => {
  for (const command of ['preview', 'publish']) {
    const calls = [];
    const client = { async rpc(name, args) {
      calls.push(args.p_command);
      return args.p_command === 'read' ? { data: { ...document, kind: 'correction' }, error: null } : { data: null, error: new Error('explicit_correction_required') };
    } };
    await assert.rejects(publicationCommand(client, { command, announcement_id: id(8), expected_revision: 2, idempotency_key: command }), /explicit_correction_required/);
    assert.deepEqual(calls, ['read', command]);
  }
});
