import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src.mjs';

const bytes = Uint8Array.from([255, 216, 255, 0]);
const uploaded = new Date('2026-11-03T00:00:00Z');
function fixture() {
  const files = new Map([['menu-images/photo.jpg', bytes], ['event-images/legacy.jpg', new Uint8Array()]]);
  const calls = [];
  function object(key, includeBody) {
    const content = files.get(key);
    if (!content) return null;
    return { size: content.length, uploaded, httpEtag: '"etag"', httpMetadata: { contentType: 'image/jpeg' },
      body: includeBody ? new ReadableStream({ start(controller) { controller.enqueue(content); controller.close(); } }) : undefined,
      writeHttpMetadata(headers) { headers.set('Content-Type', 'image/jpeg'); headers.set('Cache-Control', 'public,max-age=31536000'); },
    };
  }
  const env = { PUBLIC_IMAGES: {
    get: async (key) => { calls.push(['get', key]); return object(key, true); },
    head: async (key) => { calls.push(['head', key]); return object(key, false); },
  } };
  const request = (path, init) => worker.fetch(new Request(`https://ramap-images.example.workers.dev${path}`, init), env);
  return { request, env, files, calls };
}

test('기본 Worker 주소는 공개 사진을 원본 바이트로 제공하고 단말 캐시만 허용한다', async () => {
  const f = fixture();
  const response = await f.request('/menu-images/photo.jpg');
  assert.equal(response.status, 200);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
  assert.equal(response.headers.get('Content-Type'), 'image/jpeg');
  assert.equal(response.headers.get('ETag'), '"etag"');
  assert.equal(response.headers.get('Cache-Control'), 'private,max-age=86400,immutable');
  assert.equal(response.headers.get('CDN-Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Cloudflare-CDN-Cache-Control'), 'no-store');
});

test('비공개 사진과 임시 업로드 경로 및 임의 URL은 R2 조회 전에 거절한다', async () => {
  const f = fixture();
  for (const path of ['/profile-avatars/owner/photo.jpg', '/shop-review-images/owner/photo.jpg', '/news-report-evidence/a.jpg', '/pending/upload', '/', '/menu-images/', '/menu-images//photo.jpg', '/menu-images/%2e%2e%2fprivate.jpg', '/menu-images/%252fprivate.jpg', '/menu-images/a%5Cb.jpg', '/menu-images/%00photo.jpg', '/menu-images/a.jpg?url=https://other.example/a.jpg']) {
    assert.equal((await f.request(path)).status, 404, path);
  }
  assert.equal(f.calls.length, 0);
});

test('Worker는 파일 업로드 수정 삭제와 목록을 제공하지 않는다', async () => {
  const f = fixture();
  for (const method of ['POST', 'PUT', 'DELETE', 'PATCH']) {
    const response = await f.request('/menu-images/photo.jpg', { method });
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('Allow'), 'GET, HEAD');
  }
  assert.equal(f.calls.length, 0);
});

test('HEAD는 본문 없이 메타데이터만 반환한다', async () => {
  const f = fixture();
  const response = await f.request('/menu-images/photo.jpg', { method: 'HEAD' });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Length'), String(bytes.length));
  assert.equal((await response.arrayBuffer()).byteLength, 0);
  assert.deepEqual(f.calls, [['head', 'menu-images/photo.jpg']]);
});

test('단말의 같은 ETag 요청은 304로 응답해 바이트 전송을 줄인다', async () => {
  const f = fixture();
  for (const method of ['GET', 'HEAD']) {
    const response = await f.request('/menu-images/photo.jpg', { method, headers: { 'If-None-Match': '"other", W/"etag"' } });
    assert.equal(response.status, 304);
    assert.equal((await response.arrayBuffer()).byteLength, 0);
    assert.equal(response.headers.get('Content-Length'), null);
  }
});

test('삭제한 사진은 이전 조회 이력과 관계없이 404로 응답한다', async () => {
  const f = fixture();
  assert.equal((await f.request('/menu-images/photo.jpg')).status, 200);
  f.files.delete('menu-images/photo.jpg');
  const response = await f.request('/menu-images/photo.jpg');
  assert.equal(response.status, 404);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(f.calls.length, 2);
});

test('기존 빈 사진을 변환하지 않고 유지하며 원본 장애는 캐시하지 않는다', async () => {
  const f = fixture();
  const empty = await f.request('/event-images/legacy.jpg');
  assert.equal(empty.status, 200);
  assert.equal((await empty.arrayBuffer()).byteLength, 0);
  f.env.PUBLIC_IMAGES.get = async () => { throw new Error('internal detail'); };
  const failed = await f.request('/menu-images/photo.jpg');
  assert.equal(failed.status, 503);
  assert.equal(await failed.text(), '503');
  assert.equal(failed.headers.get('Cache-Control'), 'no-store');
});
