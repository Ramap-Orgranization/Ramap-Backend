import test from 'node:test';
import assert from 'node:assert/strict';
import { createR2Gateway } from '../r2.mjs';
import { digest } from '../policy.mjs';

const env = { R2_ACCOUNT_ID: 'a'.repeat(32), R2_PUBLIC_BUCKET: 'public', R2_PRIVATE_BUCKET: 'private', R2_ACCESS_KEY_ID: 'test', R2_SECRET_ACCESS_KEY: 'test-secret' };
const bytes = Buffer.from([255, 216, 255, 0]);
const item = { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', bucket: 'profile-avatars', path: 'owner/photo.jpg', content_type: 'image/jpeg', byte_size: bytes.length, upload_expires_at: new Date(Date.now() + 590_000).toISOString() };
const body = () => ({ transformToByteArray: async () => bytes });
function fixture(options = {}) {
  const calls = [];
  const client = { send: async (command) => {
    calls.push([command.constructor.name, command.input]);
    if (command.constructor.name === 'HeadObjectCommand') return { ContentType: options.type ?? 'image/jpeg', ContentLength: options.size ?? bytes.length, ETag: 'opaque' };
    if (command.constructor.name === 'PutObjectCommand' && options.conflict) throw { $metadata: { httpStatusCode: 412 } };
    if (command.constructor.name === 'GetObjectCommand') return { Body: body(), ContentType: 'image/jpeg', ETag: 'opaque' };
    return { ETag: 'opaque' };
  } };
  return { calls, gateway: createR2Gateway(env, client) };
}
test('R2 PUT 서명은 계정 버킷 임시 경로와 크기 타입 create-once 헤더에 결속된다', async () => {
  const gateway = createR2Gateway(env);
  const result = await gateway.signUpload(item);
  const url = new URL(result.url);
  assert.equal(url.hostname, `${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`);
  assert.equal(url.pathname, `/private/pending/${item.id}`);
  const signed = url.searchParams.get('X-Amz-SignedHeaders').split(';');
  for (const header of ['content-length', 'content-type', 'if-none-match']) assert.ok(signed.includes(header));
  assert.equal(result.headers['If-None-Match'], '*');
  assert.equal(result.headers['Content-Length'], String(bytes.length));
});
test('R2 확정은 실제 바이트를 검사하고 목적지를 다시 읽어 검증한다', async () => {
  const f = fixture();
  const saved = await f.gateway.finalize(item);
  assert.equal(saved.checksum, digest(bytes));
  assert.equal(saved.etag, 'opaque');
  assert.equal(saved.generation, undefined);
  assert.equal(f.calls.find(([name]) => name === 'PutObjectCommand')[1].IfNoneMatch, '*');
  assert.equal(f.calls.filter(([name]) => name === 'GetObjectCommand').length, 2);
});
test('R2에 잘못된 크기의 임시 파일이 있으면 최종 파일을 만들지 않는다', async () => {
  const f = fixture({ size: 99 });
  await assert.rejects(f.gateway.finalize(item), /media_metadata_mismatch/);
  assert.ok(!f.calls.some(([name]) => name === 'PutObjectCommand'));
});
test('재시도 시 이미 있는 파일의 실제 내용이 같을 때만 재사용한다', async () => {
  const f = fixture({ conflict: true });
  assert.equal((await f.gateway.store(item, bytes)).checksum, digest(bytes));
  await assert.rejects(f.gateway.store(item, Buffer.from([255, 216, 255, 1])), /media_identity_conflict/);
});
test('비공개 읽기 URL은 별도 인증 헤더 없이 사용할 수 있고 5분간만 유효하다', async () => {
  const gateway = createR2Gateway(env);
  const { url } = await gateway.signRead({ physical_bucket: 'private', object_key: 'profile-avatars/owner/photo.jpg', etag: 'opaque' });
  const parsed = new URL(url);
  assert.equal(parsed.searchParams.get('X-Amz-Expires'), '300');
  assert.equal(parsed.searchParams.get('X-Amz-SignedHeaders'), 'host');
  assert.equal(parsed.searchParams.get('response-cache-control'), 'private,no-store');
});
test('다른 버킷을 서명하거나 다른 ETag 파일을 삭제하지 않는다', async () => {
  const f = fixture();
  await assert.rejects(f.gateway.signRead({ physical_bucket: 'other', object_key: 'file' }), /media_location_unavailable/);
  await assert.rejects(f.gateway.remove({ bucket: 'private', path: 'file', etag: 'different' }), /media_identity_conflict/);
  assert.ok(!f.calls.some(([name]) => name === 'DeleteObjectCommand'));
});
test('R2 설정이 없으면 연결을 활성화하지 않는다', () => {
  assert.equal(createR2Gateway({}), null);
  assert.throws(() => createR2Gateway({ R2_ACCOUNT_ID: 'other' }), /Invalid R2 configuration/);
});

test('공개 CDN purge가 설정되지 않으면 삭제 완료를 보고하지 않는다', async () => {
  const client = { send: async () => ({ ETag: 'opaque' }) };
  const gateway = createR2Gateway({ ...env, R2_PUBLIC_BASE_URL: 'https://images.example.com' }, client);
  await assert.rejects(gateway.remove({ bucket: 'public', path: 'menu-images/photo.jpg' }), /media_cache_cleanup_pending/);
});

test('Worker 캐시 삭제 인증이 없으면 사진 정리 완료를 보고하지 않는다', async () => {
  const calls = [];
  const client = { send: async (command) => { calls.push(command.constructor.name); return { ETag: 'opaque' }; } };
  const gateway = createR2Gateway({ ...env, R2_PUBLIC_DELIVERY: 'worker', R2_PUBLIC_BASE_URL: 'https://ramap-images.example.workers.dev' }, client);
  await assert.rejects(gateway.remove({ bucket: 'public', path: 'menu-images/photo.jpg' }), /media_cache_cleanup_pending/);
  assert.deepEqual(calls, ['HeadObjectCommand', 'DeleteObjectCommand']);
});

test('Worker 제공 방식에 임의 호스트와 r2 개발 주소를 설정하지 않는다', () => {
  for (const url of ['https://other.example.com', 'https://example.r2.dev', 'https://worker.example.workers.dev/other', 'http://worker.example.workers.dev']) {
    assert.throws(() => createR2Gateway({ ...env, R2_PUBLIC_DELIVERY: 'worker', R2_PUBLIC_BASE_URL: url }), /Invalid public Worker URL/);
  }
});
