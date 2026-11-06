// Run only against dedicated staging buckets; never create production/user fixtures.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createR2Gateway } from './r2.mjs';
import { digest } from './policy.mjs';

const env = process.env;
if (env.R2_SMOKE !== 'staging' || ![env.R2_PUBLIC_BUCKET, env.R2_PRIVATE_BUCKET].every((b) => /(^|-)(staging|test)(-|$)/.test(b ?? ''))) {
  throw new Error('Dedicated staging R2 buckets and R2_SMOKE=staging are required');
}
const storage = createR2Gateway(env);
const id = randomUUID();
const bytes = Buffer.from([255, 216, 255, 0]);
const item = { id, bucket: 'profile-avatars', path: `smoke/${id}.jpg`, content_type: 'image/jpeg', byte_size: bytes.length,
  upload_expires_at: new Date(Date.now() + 590_000).toISOString() };
const pending = { bucket: storage.pendingBucket, path: `pending/${id}` };
const final = { bucket: storage.finalBucket(item.bucket), path: `${item.bucket}/${item.path}` };
let phase = 'prepare';
try {
  const signed = await storage.signUpload(item);
  const headers = { ...signed.headers };
  phase = 'wrong_mime_rejected';
  const wrong = await fetch(signed.url, { method: 'PUT', headers: { ...headers, 'Content-Type': 'image/png' }, body: bytes, redirect: 'error' });
  assert.ok(!wrong.ok);
  phase = 'put';
  const uploaded = await fetch(signed.url, { method: 'PUT', headers, body: bytes, redirect: 'error' });
  assert.ok(uploaded.ok);
  phase = 'overwrite_rejected';
  const duplicate = await fetch(signed.url, { method: 'PUT', headers, body: bytes, redirect: 'error' });
  assert.equal(duplicate.status, 412);
  phase = 'finalize';
  const verified = await storage.finalize(item);
  assert.equal(verified.checksum, digest(bytes));
  phase = 'signed_read';
  const read = await storage.signRead({ physical_bucket: final.bucket, object_key: final.path, etag: verified.etag });
  const response = await fetch(read.url, { redirect: 'error' });
  assert.ok(response.ok);
  assert.equal(digest(Buffer.from(await response.arrayBuffer())), digest(bytes));
  phase = 'anonymous_private_read_rejected';
  const anonymous = new URL(read.url);
  anonymous.search = '';
  assert.ok(!(await fetch(anonymous, { redirect: 'error' })).ok);
  phase = 'complete';
  console.log(JSON.stringify({ passed: true, tested: ['signed_mime', 'create_once', 'finalize', 'sha256', 'signed_read', 'private_denial'],
    public_cdn_tested: false, supabase_permissions_tested: false, exact_length_rejection_tested: false }));
} catch {
  console.error(JSON.stringify({ passed: false, phase }));
  process.exitCode = 1;
} finally {
  const removed = await Promise.allSettled([storage.remove(pending), storage.remove(final)]);
  if (removed.some((r) => r.status === 'rejected')) { console.error('Staging cleanup requires retry'); process.exitCode = 1; }
}
