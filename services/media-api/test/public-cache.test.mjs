import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createR2Gateway } from '../r2.mjs';
import { purgeWorkerImages } from '../public-cache.mjs';

const env = { R2_ACCOUNT_ID: 'a'.repeat(32), R2_PUBLIC_BUCKET: 'public', R2_PRIVATE_BUCKET: 'private',
  R2_PUBLIC_DELIVERY: 'worker', R2_PUBLIC_BASE_URL: 'https://ramap-images.account.workers.dev', R2_WORKER_PURGE_SECRET: 'test-secret' };
const jobs = [1, 2].map(id => ({ id, bucket: 'public', path: `menu-images/${id}.jpg` }));

test('여러 파일 삭제 뒤 한 번의 인증된 purge와 404 확인을 거쳐 완료한다', async t => {
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    calls.push({ url, init });
    if (init.method === 'HEAD') return new Response(null, { status: 404 });
    const timestamp = init.headers['X-Ramap-Purge-Timestamp'];
    assert.equal(init.headers['X-Ramap-Purge-Signature'], createHmac('sha256', env.R2_WORKER_PURGE_SECRET).update(`${timestamp}\n${init.body}`).digest('hex'));
    return Response.json({ success: true });
  });
  const deleted = [];
  const gateway = createR2Gateway(env, { send: async command => {
    if (command.constructor.name === 'DeleteObjectCommand') deleted.push(command.input.Key);
    return { ETag: 'etag' };
  } });
  assert.deepEqual(await gateway.removeBatch(jobs), new Map([[1, true], [2, true]]));
  assert.equal(calls.filter(c => c.init.method === 'POST').length, 1);
  assert.deepEqual(JSON.parse(calls[0].init.body).paths, jobs.map(j => j.path));
  assert.deepEqual(deleted, jobs.map(j => j.path));
  assert.equal(calls.filter(c => c.init.method === 'HEAD').length, 2);
});

test('이미 R2에서 사라진 파일도 재시도에서 캐시 정리를 완료한다', async t => {
  let purged = 0;
  t.mock.method(globalThis, 'fetch', async (_, init) => {
    if (init.method === 'HEAD') return new Response(null, { status: 404 });
    purged++; return Response.json({ success: true });
  });
  const gateway = createR2Gateway(env, { send: async () => { throw { name: 'NotFound' }; } });
  await gateway.remove(jobs[0]);
  assert.equal(purged, 1);
});

test('purge 실패 시 공개 파일만 재시도로 남기고 비공개 삭제는 완료한다', async t => {
  t.mock.method(globalThis, 'fetch', async () => Response.json({ success: false }));
  const gateway = createR2Gateway(env, { send: async () => ({ ETag: 'etag' }) });
  const results = await gateway.removeBatch([...jobs, { id: 3, bucket: 'private', path: 'profile-avatars/a.jpg' }]);
  assert.deepEqual(results, new Map([[1, false], [2, false], [3, true]]));
});

test('purge가 수락되어도 이전 이미지가 남아 있으면 완료하지 않는다', async t => {
  t.mock.method(globalThis, 'fetch', async (_, init) => init.method === 'HEAD' ? new Response(null, { status: 200 }) : Response.json({ success: true }));
  await assert.rejects(purgeWorkerImages(env, [jobs[0].path]), /media_cache_cleanup_pending/);
});
