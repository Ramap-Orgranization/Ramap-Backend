import assert from 'node:assert/strict';
import test from 'node:test';
import { createMediaApi } from '../api.mjs';
import { digest, MediaError, validateBytes } from '../policy.mjs';

const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const image = { bucket: 'shop-review-images', path: `${id}/${id}.jpg` };
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0x00]);

function fixture(overrides = {}) {
  const calls = [];
  const item = { ...image, id, state: 'pending', owner_id: id, byte_size: jpeg.length, content_type: 'image/jpeg', upload_provider: 'r2', required_providers: [] };
  const service = {
    rpc: async (name, params) => {
      calls.push([name, params]);
      const data = ['claim_media_cleanup', 'claim_account_media_cleanup'].includes(name) ? [] : item;
      return { data, error: null };
    },
    storage: { from: () => assert.fail('사진 전송을 Supabase Storage로 우회함') },
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
  assert.equal((await f.request('internal/v2/prepare', image, 'wrong-secret')).status, 401);
  assert.equal(f.calls.filter(([name]) => name !== 'authenticate').length, 0);
});

test('종료한 사진 API 경로는 인증이나 저장소 작업 없이 404를 반환한다', async () => {
  const f = fixture();
  for (const path of ['v1/resolve', 'v1/account/cleanup', 'internal/prepare']) {
    const response = await f.request(path, {}, 'server-secret');
    assert.equal(response.status, 404);
    assert.deepEqual(await response.json(), { code: 'not_found' });
  }
  assert.deepEqual(f.calls, []);
});

test('만료된 사용자 인증을 익명 읽기로 낮추지 않는다', async () => {
  const f = fixture();
  assert.equal((await f.request('v2/resolve', { images: [image] }, 'expired')).status, 401);
});

test('R2 파일 검증과 확정으로만 업로드를 완료한다', async () => {
  const f = fixture();
  const response = await f.request('v2/finalize', { id });
  assert.equal(response.status, 200);
  const [, completion] = f.calls.find(([name]) => name === 'complete_media_upload_v2');
  assert.deepEqual(completion.p_locations, [
    { provider: 'r2', bucket: 'private', path: `${image.bucket}/${image.path}`, etag: 'opaque' },
  ]);
});

test('호환 복사 조건이 남아 있는 이전 업로드는 완료하지 않는다', async () => {
  const f = fixture();
  f.item.required_providers = ['supabase'];
  f.r2.finalize = async () => assert.fail('종료한 호환 업로드를 확정함');
  assert.equal((await f.request('v2/finalize', { id })).status, 409);
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
    return { data: name === 'account_has_external_media' ? true : [], error: null };
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
    if (name === 'list_account_review_photo_copies') return { data: [] };
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
    if (name === 'list_account_review_photo_copies') return { data: [] };
    return { data: name === 'claim_account_media_cleanup' ? [{ id: 1, provider: 'r2', bucket: 'private', path: 'own.jpg' }] : false };
  };
  f.r2.remove = async () => { throw new Error('offline'); };
  assert.equal((await f.request('v2/account/cleanup')).status, 503);
  assert.ok(f.calls.some(([name, params]) => name === 'finish_media_cleanup' && !params.p_success));
});

test('탈퇴 리뷰는 R2 복사가 검증된 뒤에만 원본 정리를 시작한다', async () => {
  const f = fixture();
  const destination = 'withdrawn/' + id + '/1.jpg';
  const reserved = { ...f.item, path: destination, checksum: digest(jpeg), upload_expires_at: 'attempt-deadline' };
  let copied = false;
  let uploadFails = true;
  f.service.rpc = async (name, params) => {
    f.calls.push([name, params]);
    if (name === 'list_account_review_photo_copies') {
      return { data: copied ? [] : [{ source_path: image.path, destination_path: destination }] };
    }
    if (name === 'reserve_withdrawn_review_photo') {
      assert.deepEqual(params, { p_user_id: id, p_source_path: image.path, p_destination_path: destination, p_bucket: 'private' });
      return { data: reserved };
    }
    if (name === 'fetch_service_media') {
      assert.equal(params.p_path, image.path);
      return { data: { state: 'ready', locations: [
        { provider: 'supabase', verified: true, path: image.path },
        { provider: 'r2', verified: true, path: image.path, etag: 'source' },
      ] } };
    }
    if (name === 'finish_withdrawn_review_photo') {
      assert.deepEqual(params, { p_user_id: id, p_id: id, p_expires_at: 'attempt-deadline', p_etag: 'destination', p_checksum: digest(jpeg) });
      copied = true;
    }
    if (name === 'prepare_account_media_cleanup') assert.ok(copied);
    return { data: name === 'claim_account_media_cleanup' ? [] : false };
  };
  f.r2.read = async (location) => {
    assert.equal(location.etag, 'source');
    return { bytes: jpeg, contentType: 'image/jpeg' };
  };
  f.r2.store = async (item, bytes) => {
    assert.equal(item.path, destination);
    assert.deepEqual(bytes, jpeg);
    if (uploadFails) throw new Error('offline');
    return { etag: 'destination', checksum: digest(bytes) };
  };

  assert.equal((await f.request('v2/account/cleanup')).status, 503);
  assert.ok(!f.calls.some(([name]) => name === 'finish_withdrawn_review_photo' || name === 'prepare_account_media_cleanup'));
  uploadFails = false;
  assert.equal((await f.request('v2/account/cleanup')).status, 200);
  assert.ok(f.calls.some(([name]) => name === 'prepare_account_media_cleanup'));
});

test('사진 서명은 DB에서 허용한 경로 중 R2 위치만 반환한다', async () => {
  const f = fixture();
  const legacy = { ...image, path: 'legacy.jpg' };
  const denied = { ...image, path: 'denied.jpg' };
  const requested = [legacy, image, denied];
  f.service.rpc = async (name, params) => {
    assert.equal(name, 'resolve_media_locations_v2');
    assert.deepEqual(params.p_images, requested);
    return { data: [
      { ...legacy, provider: 'supabase', object_key: legacy.path },
      { ...image, provider: 'r2', object_key: image.path },
    ] };
  };
  f.r2.signRead = async (location) => {
    assert.equal(location.object_key, image.path);
    return { url: 'signed', expires_at: 'future' };
  };
  const response = await f.request('v2/resolve', { images: requested });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), [{ ...image, url: 'signed', expires_at: 'future' }]);
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
