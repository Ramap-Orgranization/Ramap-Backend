import assert from 'node:assert/strict';
import test from 'node:test';
import { publishPendingOperatingNotices } from './operating-notice-publication.ts';
import { fact, id, source } from './notification-fixtures.mjs';

function harness(documents, failPublish = false) {
  const calls = [];
  const client = { async rpc(name, args) {
    calls.push({ name, args });
    if (name === 'fetch_pending_operating_notice_publications') return { data: documents.map((document, i) => ({ notice_id: id(i + 20), document })) };
    if (name === 'publish_operating_notice_notification') return failPublish ? { error: { message: 'operating_notice_changed' } } : { data: args.p_document ? { published: true } : { skipped: true } };
    return { data: null };
  } };
  return { calls, run: () => publishPendingOperatingNotices(client, 20) };
}
const document = () => ({ source, facts: [fact({ registration_type: 'operating_notice', registration_id: id(20) })] });

test('canonical notice uses validated document and skips expired or linked rows', async () => {
  const app = harness([document(), null]);
  assert.deepEqual(await app.run(), { published: 1, skipped: 1, failed: 0 });
  assert.deepEqual(app.calls.find(c => c.name === 'publish_operating_notice_notification').args.p_document, document());
});
test('invalid content never publishes and does not block the next valid notice', async () => {
  const invalid = document(); invalid.facts[0].message = 'x'.repeat(501);
  const app = harness([invalid, document()]);
  assert.deepEqual(await app.run(), { published: 1, skipped: 0, failed: 1 });
  assert.equal(app.calls.filter(c => c.name === 'publish_operating_notice_notification').length, 1);
  assert.equal(app.calls.find(c => c.name === 'record_operating_notice_publication_failure').args.p_error, 'invalid_fact_text');
});
test('a concurrent canonical edit is recorded for bounded retry, without sending', async () => {
  const app = harness([document()], true);
  assert.deepEqual(await app.run(), { published: 0, skipped: 0, failed: 1 });
  assert.equal(app.calls.at(-1).args.p_error, 'operating_notice_changed');
});

test('해석이 필요한 자동 공지는 검수 필요로 기록하고 다음 공지는 계속 처리한다', async () => {
  const ambiguous = { source, facts: [fact({ id: id(20), registration_type: 'operating_notice', registration_id: id(20), context_key: `operating-notice-${id(20)}`, message: '저녁부터 휴무' })] };
  const app = harness([ambiguous, document()]);
  assert.deepEqual(await app.run(), { published: 1, skipped: 0, failed: 1 });
  assert.equal(app.calls.filter(c => c.name === 'publish_operating_notice_notification').length, 1);
  assert.equal(app.calls.find(c => c.name === 'record_operating_notice_publication_failure').args.p_error, 'operating_notice_copy_review_required');
});
