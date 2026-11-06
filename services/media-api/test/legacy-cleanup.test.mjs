import assert from 'node:assert/strict';
import test from 'node:test';
import { createLegacyGcsCleanup } from '../legacy-cleanup.mjs';

const env = { LEGACY_GCS_CLEANUP_BUCKETS: 'old-private;old-public' };
const job = { bucket: 'old-private', path: 'profile-avatars/user/photo.jpg', generation: '9007199254740993' };
const notFound = () => Object.assign(new Error('missing'), { response: { status: 404 } });

test('이전 저장소 설정 없이는 삭제 클라이언트를 활성화하지 않는다', () => {
  assert.equal(createLegacyGcsCleanup({}), null);
  assert.throws(() => createLegacyGcsCleanup({ LEGACY_GCS_CLEANUP_BUCKETS: 'https://unexpected.test' }), /Invalid/);
});

test('기록된 버킷과 세대만 삭제하고 soft delete 보존이 끝났는지 확인한다', async () => {
  const calls = [];
  const cleanup = createLegacyGcsCleanup(env, { request: async (options) => {
    calls.push(options);
    if (options.method === 'GET') throw notFound();
    return { status: 204 };
  } });
  await cleanup.remove(job);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, 'https://storage.googleapis.com/storage/v1/b/old-private/o/profile-avatars%2Fuser%2Fphoto.jpg');
  assert.deepEqual(calls[0].params, { generation: job.generation, ifGenerationMatch: job.generation });
  assert.equal(calls[1].params.softDeleted, true);
  assert.equal(calls[1].params.generation, job.generation);
});

test('이미 삭제되어 실제로 없는 세대의 재시도는 성공한다', async () => {
  const cleanup = createLegacyGcsCleanup(env, { request: async () => { throw notFound(); } });
  await cleanup.remove(job);
});

test('soft delete 보존 중인 복사본은 삭제 완료로 처리하지 않는다', async () => {
  const cleanup = createLegacyGcsCleanup(env, { request: async ({ method }) => {
    if (method === 'DELETE') throw notFound();
    return { data: { generation: job.generation, hardDeleteTime: 'future' } };
  } });
  await assert.rejects(cleanup.remove(job), /media_cleanup_pending/);
});

test('다른 버킷이나 세대가 없는 이력은 요청 전에 거절한다', async () => {
  const cleanup = createLegacyGcsCleanup(env, { request: async () => assert.fail('검증되지 않은 삭제 요청') });
  await assert.rejects(cleanup.remove({ ...job, bucket: 'unrelated' }), /media_location_unavailable/);
  await assert.rejects(cleanup.remove({ ...job, generation: null }), /media_identity_unavailable/);
});

test('권한 거절과 세대 충돌을 이미 삭제된 것으로 처리하지 않는다', async () => {
  for (const status of [403, 412, 503]) {
    const failure = Object.assign(new Error('rejected'), { response: { status } });
    const cleanup = createLegacyGcsCleanup(env, { request: async () => { throw failure; } });
    await assert.rejects(cleanup.remove(job), (error) => error === failure);
  }
});
