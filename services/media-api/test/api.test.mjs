import assert from 'node:assert/strict';
import test from 'node:test';
import { createMediaApi } from '../api.mjs';
import { digest, MediaError, validateBytes } from '../policy.mjs';

const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const image = { bucket: 'shop-review-images', path: `${id}/${id}.jpg` };
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0x00]);

function fixture(overrides = {}) {
  const calls = [];
  const item = { ...image, id, state: 'pending', owner_id: id, byte_size: jpeg.length, content_type: 'image/jpeg', legacy_required: true, upload_provider: 'r2', required_providers: ['supabase'] };
  const service = {
    rpc: async (name, params) => {
      calls.push([name, params]);
      const data = ['claim_media_cleanup', 'claim_account_media_cleanup'].includes(name) ? [] : item;
      return { data, error: null };
    },
    storage: { from: () => ({ upload: async () => { calls.push(['mirror']); return { error: null }; } }) },
  };
  const r2 = {
    pendingBucket: 'private', finalBucket: () => 'private',
    signUpload: async () => ({ url: 'https://account.r2.cloudflarestorage.com/private/pending/example', headers: {} }),
    finalize: async () => ({ bucket: 'private', path: `${image.bucket}/${image.path}`, etag: 'opaque', checksum: digest(jpeg), bytes: jpeg }),
    signRead: async () => ({ url: 'signed', expires_at: 'future' }),
  };
  const authenticate = async (token) => {
    calls.push(['authenticate', token]);
    if (token === 'expired') throw new MediaError(401, 'authentication_required');
    return { client: service, userId: token ? id : null };
  };
  const api = createMediaApi({ service, r2, authenticate, internalKey: 'server-secret', ...overrides });
  async function request(path, body = {}, token = 'user-token') {
    return api.handle(new Request(`https://media.test/${path}`, { method: 'POST', headers: { ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) }));
  }
  return { api, request, calls, service, item, r2 };
}

test('인증하지 않은 업로드와 위조 내부 요청은 DB에 도달하지 않는다', async () => {
  const f = fixture();
  assert.equal((await f.request('v2/prepare', image, null)).status, 401);
  assert.equal((await f.request('internal/prepare', image, 'wrong-secret')).status, 401);
  assert.equal(f.calls.filter(([name]) => name !== 'authenticate').length, 0);
});

test('만료된 사용자 인증을 익명 읽기로 낮추지 않는다', async () => {
  const f = fixture();
  assert.equal((await f.request('v2/resolve', { images: [image] }, 'expired')).status, 401);
});

test('파일 검증과 구버전 복사가 모두 끝나야 ready를 기록한다', async () => {
  const f = fixture();
  const response = await f.request('v2/finalize', { id });
  assert.equal(response.status, 200);
  assert.ok(f.calls.findIndex(([name]) => name === 'mirror') < f.calls.findIndex(([name]) => name === 'complete_media_upload_v2'));
});

test('구버전 복사 실패는 완료를 기록하지 않고 재시도 가능하게 남긴다', async () => {
  const f = fixture();
  f.service.storage.from = () => ({ upload: async () => ({ error: { statusCode: '503' } }) });
  assert.equal((await f.request('v2/finalize', { id })).status, 503);
  assert.ok(!f.calls.some(([name]) => name === 'complete_media_upload_v2'));
});

test('이미 완료한 업로드 재요청은 파일을 다시 복사하지 않는다', async () => {
  const f = fixture();
  f.item.state = 'ready';
  f.r2.finalize = async () => assert.fail('완료된 파일을 다시 복사함');
  assert.equal((await f.request('v2/finalize', { id })).status, 200);
});

test('prepare는 실제 권한과 경로를 DB에서 검사하고 만료 청소를 예약한다', async () => {
  const f = fixture();
  const response = await f.request('v2/prepare', { ...image, byte_size: 4, content_type: 'image/jpeg' });
  assert.equal(response.status, 200);
  assert.deepEqual(f.calls.filter(([name]) => name !== 'authenticate').map(([name]) => name), ['prepare_media_upload_v2', 'register_media_targets_v2']);
});

test('경로 탈출과 큰 배치는 서명하지 않는다', async () => {
  const f = fixture();
  assert.equal((await f.request('v2/resolve', { images: [{ ...image, path: '../secret.jpg' }] })).status, 400);
  assert.equal((await f.request('v2/resolve', { images: Array(65).fill(image) })).status, 400);
});

test('삭제 실패는 성공으로 응답하지 않고 outbox 재시도로 남긴다', async () => {
  const f = fixture();
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'delete_media_object' ? id : name === 'claim_media_cleanup' ? [{ id: 1, media_id: id, provider: 'r2', bucket: 'private', path: 'file' }] : null, error: null };
  };
  f.r2.remove = async () => { throw new Error('offline'); };
  assert.equal((await f.request('v2/delete', image)).status, 503);
  assert.ok(f.calls.some(([name, params]) => name === 'finish_media_cleanup' && params.p_success === false));
});

test('헤더가 맞아도 실제 파일 크기와 이미지 signature가 다르면 거절한다', () => {
  assert.equal(validateBytes(jpeg, { byte_size: 4, content_type: 'image/jpeg' }), digest(jpeg));
  assert.throws(() => validateBytes(jpeg, { byte_size: 5, content_type: 'image/jpeg' }), /size_mismatch/);
  assert.throws(() => validateBytes(Buffer.from('text'), { byte_size: 4, content_type: 'image/png' }), /type_mismatch/);
});

test('다른 worker가 삭제 lease를 보유해도 외부 사진이 남으면 탈퇴 완료로 응답하지 않는다', async () => {
  const f = fixture();
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'claim_account_media_cleanup' ? [] : name === 'account_has_external_media' ? true : null, error: null };
  };
  assert.equal((await f.request('v2/account/cleanup')).status, 503);
  assert.ok(f.calls.some(([name, params]) => name === 'prepare_account_media_cleanup' && params.p_user_id === id));
});

test('타인의 정리 실패와 대기 작업은 사진 없는 사용자의 탈퇴를 막지 않는다', async () => {
  const f = fixture();
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    if (name === 'claim_media_cleanup') return { data: [{ id: 1, provider: 'r2', bucket: 'private', path: 'other-user.jpg' }] };
    if (name === 'claim_account_media_cleanup') {
      assert.equal(params.p_user_id, id);
      return { data: [] };
    }
    return { data: false };
  };
  f.r2.remove = async () => { throw new Error('other user offline'); };
  const response = await f.request('v2/account/cleanup');
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { deleted: true });
  assert.ok(f.calls.some(([name]) => name === 'account_has_external_media'));
  assert.ok(!f.calls.some(([name]) => name === 'claim_media_cleanup'));
});

test('자기 계정의 실제 삭제 실패는 재시도 대상으로 남고 탈퇴를 완료하지 않는다', async () => {
  const f = fixture();
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'claim_account_media_cleanup' ? [{ id: 1, provider: 'r2', bucket: 'private', path: 'own.jpg' }] : false };
  };
  f.r2.remove = async () => { throw new Error('offline'); };
  assert.equal((await f.request('v2/account/cleanup')).status, 503);
  assert.ok(f.calls.some(([name, params]) => name === 'finish_media_cleanup' && !params.p_success));
});

test('Supabase 사진 64개는 권한 검사 후 한 번에 서명하고 경로별로 대응한다', async () => {
  const images = Array.from({ length: 64 }, (_, index) => ({ bucket: image.bucket, path: `${id}/${index}.jpg` }));
  const f = fixture();
  f.service.rpc = async (name) => {
    assert.equal(name, 'resolve_media_locations_v2');
    return { data: images.map((entry) => ({ ...entry, provider: 'supabase', physical_bucket: entry.bucket, object_key: entry.path })) };
  };
  let batches = 0;
  f.service.storage.from = (bucket) => ({
    createSignedUrls: async (paths, seconds) => {
      batches++;
      assert.equal(bucket, image.bucket);
      assert.deepEqual(paths, images.map((entry) => entry.path));
      assert.equal(seconds, 300);
      return { data: paths.toReversed().map((path) => ({ path, signedUrl: `https://storage.test/${path}` })) };
    },
  });
  const response = await f.request('v2/resolve', { images });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).map(({ path, url }) => [path, url]), images.map(({ path }) => [path, `https://storage.test/${path}`]));
  assert.equal(batches, 1);
});

test('버킷별 부분 서명 실패와 누락 및 중복 응답을 다른 사진에 적용하지 않는다', async () => {
  const locations = [
    { bucket: 'profile-avatars', path: 'one', provider: 'supabase', physical_bucket: 'avatars', object_key: 'one' },
    { bucket: 'profile-avatars', path: 'missing', provider: 'supabase', physical_bucket: 'avatars', object_key: 'missing' },
    { bucket: 'profile-avatars', path: 'denied', provider: 'supabase', physical_bucket: 'avatars', object_key: 'denied' },
    { bucket: 'profile-avatars', path: 'duplicate', provider: 'supabase', physical_bucket: 'avatars', object_key: 'duplicate' },
    { bucket: 'shop-review-images', path: 'failed', provider: 'supabase', physical_bucket: 'reviews', object_key: 'failed' },
    { bucket: 'shop-review-images', path: 'r2', provider: 'r2' },
  ];
  const user = {
    rpc: async () => ({ data: locations }),
    storage: { from: (bucket) => ({ createSignedUrls: async () => bucket === 'reviews' ? { error: new Error('offline') } : {
      data: [{ path: 'one', signedUrl: 'one-url' }, { path: 'denied', error: 'denied', signedUrl: 'forbidden' },
        { path: 'duplicate', signedUrl: 'first' }, { path: 'duplicate', signedUrl: 'second' }, { path: 'unrequested', signedUrl: 'ignored' }],
    } }) },
  };
  const f = fixture({ authenticate: async () => ({ client: user, userId: id }) });
  f.service.storage.from = () => assert.fail('사용자 서명을 service role로 우회함');
  const response = await f.request('v2/resolve', { images: locations.map(({ bucket, path }) => ({ bucket, path })) });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).map(({ url }) => url), ['one-url', null, null, null, null, 'signed']);
});

test('이전 GCS 복사본은 삭제 전용 경로에서 확인한 뒤에만 완료로 기록한다', async () => {
  const removed = [];
  const job = { id: 8, provider: 'gcs', bucket: 'old-private', path: 'profile-avatars/old.jpg', generation: '9' };
  const f = fixture({ legacyCleanup: { remove: async (entry) => removed.push(entry) } });
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'claim_media_cleanup' ? [job] : null };
  };
  f.r2.remove = async () => assert.fail('GCS 파일을 R2로 삭제함');
  assert.equal(await f.api.cleanup(), 1);
  assert.deepEqual(removed, [job]);
  assert.ok(f.calls.some(([name, params]) => name === 'finish_media_cleanup' && params.p_success));
});

test('이전 저장소 삭제 설정이 없으면 완료를 기록하지 않는다', async () => {
  const f = fixture();
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'claim_media_cleanup' ? [{ id: 8, provider: 'gcs', bucket: 'old-private', path: 'old.jpg', generation: '9' }] : null };
  };
  await assert.rejects(f.api.cleanup(), /media_cleanup_pending/);
  assert.ok(f.calls.some(([name, params]) => name === 'finish_media_cleanup' && !params.p_success));
});

test('내부 사진 복사는 검증한 R2 bytes를 새 공개 사진으로 확정한다', async () => {
  const f = fixture();
  const source = { state: 'ready', locations: [{ provider: 'r2', verified: true, bucket: 'private', path: 'evidence', etag: 'opaque' }] };
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'fetch_service_media' && !params.p_id ? source : f.item, error: null };
  };
  f.r2.read = async (location) => {
    assert.equal(location, source.locations[0]);
    return { bytes: jpeg, contentType: 'image/jpeg' };
  };
  f.r2.stage = async (item, bytes) => { assert.equal(item.id, id); assert.deepEqual(bytes, jpeg); };
  const response = await f.request('internal/v2/copy', { bucket: 'event-images', path: 'events/example.jpg', source: image }, 'server-secret');
  assert.equal(response.status, 200);
  assert.ok(f.calls.some(([name, params]) => name === 'prepare_service_media_v2' && params.p_bucket === 'event-images' && params.p_byte_size === jpeg.length));
  assert.ok(f.calls.some(([name]) => name === 'complete_media_upload_v2'));
});

test('제거한 저장소 provider를 다른 저장소로 잘못 삭제하지 않는다', async () => {
  const f = fixture();
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'claim_media_cleanup' ? [{ id: 1, provider: 'removed_storage', path: 'file' }] : null };
  };
  f.r2.remove = async () => assert.fail('미지원 provider를 R2로 처리함');
  await assert.rejects(f.api.cleanup(), /media_cleanup_pending/);
  assert.ok(f.calls.some(([name, params]) => name === 'finish_media_cleanup' && !params.p_success));
});

test('종료된 이벤트 사진은 내부 복사 요청에도 파일을 읽거나 쓰지 않는다', async () => {
  const f = fixture();
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    return { data: name === 'media_copy_eligibility' ? { needed: false, reason: 'ended_event' } : null };
  };
  f.r2.store = async () => assert.fail('종료된 사진을 R2에 씀');
  const response = await f.request('internal/v2/backfill', { bucket: 'event-images', path: 'expired.jpg', provider: 'r2', source: { provider: 'supabase' } }, 'server-secret');
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { copied: false, skipped: true, reason: 'ended_event' });
  assert.deepEqual(f.calls.map(([name]) => name), ['media_copy_eligibility']);
});
