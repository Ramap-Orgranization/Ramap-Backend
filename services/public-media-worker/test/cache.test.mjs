import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import worker from '../src.mjs';
import { cacheTag } from '../cache.mjs';

const secret = 'test-secret-only';
const path = 'menu-images/photo.jpg';
function signed(paths, options = {}) {
  const body = JSON.stringify({ paths });
  const timestamp = String(Math.floor(Date.now() / 1000) + (options.offset ?? 0));
  const signature = createHmac('sha256', options.secret ?? secret).update(`${timestamp}\n${body}`).digest('hex');
  return new Request('https://fixture.workers.dev/internal/cache/purge', { method: 'POST', headers: {
    'X-Ramap-Purge-Timestamp': timestamp, 'X-Ramap-Purge-Signature': signature,
  }, body });
}
const env = { PUBLIC_CACHE_PURGE_SECRET: secret };

test('공개 사진 묶음만 서명을 확인한 뒤 같은 entrypoint 캐시에서 지운다', async () => {
  let received;
  const result = await worker.fetch(signed([path, path, 'event-images/second.jpg']), env, { cache: { purge: async args => {
    received = args; return { success: true };
  } } });
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('Cache-Control'), 'no-store');
  assert.deepEqual(received, { tags: await Promise.all([path, 'event-images/second.jpg'].map(cacheTag)) });
});

test('인증 누락 변조 만료와 비공개 경로 요청은 purge를 실행하지 않는다', async () => {
  const ctx = { cache: { purge: () => { throw new Error('must not call'); } } };
  for (const request of [signed([path], { secret: 'wrong' }), signed([path], { offset: -120 }), new Request('https://fixture.workers.dev/internal/cache/purge', { method: 'POST' })]) {
    assert.equal((await worker.fetch(request, env, ctx)).status, 401);
  }
  for (const paths of [[], ['profile-avatars/a.jpg'], ['menu-images/../a.jpg'], ['menu-images/a%20b.jpg'], Array(101).fill(path)]) {
    assert.equal((await worker.fetch(signed(paths), env, ctx)).status, 400);
  }
});

test('purge 거절과 런타임 오류를 완료 응답으로 바꾸지 않는다', async () => {
  for (const purge of [async () => ({ success: false }), async () => { throw new Error('offline'); }]) {
    assert.equal((await worker.fetch(signed([path]), env, { cache: { purge } })).status, 503);
  }
});

test('공개 이미지만 한 시간 CDN 캐시와 파일별 태그를 제공한다', async () => {
  const object = { size: 1, uploaded: new Date(), httpEtag: '"etag"', httpMetadata: { contentType: 'image/jpeg' },
    writeHttpMetadata() {}, body: new Uint8Array([1]) };
  const response = await worker.fetch(new Request(`https://fixture.workers.dev/${path}`), {
    ...env, EDGE_CACHE_ENABLED: 'true', PUBLIC_IMAGES: { get: async () => object },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cloudflare-CDN-Cache-Control'), 'public,max-age=3600,must-revalidate');
  assert.equal(response.headers.get('Cache-Control'), 'private,max-age=86400,immutable');
  assert.equal(response.headers.get('Cache-Tag'), await cacheTag(path));
  const unconfigured = await worker.fetch(new Request(`https://fixture.workers.dev/${path}`), {
    EDGE_CACHE_ENABLED: 'true', PUBLIC_IMAGES: { get: async () => object },
  });
  assert.equal(unconfigured.headers.get('Cloudflare-CDN-Cache-Control'), 'no-store');
});
