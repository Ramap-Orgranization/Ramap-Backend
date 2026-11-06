import { purgeWorkerImages } from './public-cache.mjs';
import { S3Client, PutObjectCommand, GetObjectCommand, HeadObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { digest, MediaError, PUBLIC_BUCKETS, validateBytes, requireWriteWindow } from './policy.mjs';

const missing = (error) => ['NoSuchKey', 'NotFound'].includes(error.name) || error.$metadata?.httpStatusCode === 404;
const conflict = (error) => error.$metadata?.httpStatusCode === 412;
const timeout = () => ({ abortSignal: AbortSignal.timeout(30_000) });

export function createR2Gateway(env, suppliedClient, presign = getSignedUrl) {
  if (!env.R2_ACCOUNT_ID && !suppliedClient) return null;
  if (!/^[a-f0-9]{32}$/.test(env.R2_ACCOUNT_ID ?? '') || !env.R2_PUBLIC_BUCKET || !env.R2_PRIVATE_BUCKET
    || env.R2_PUBLIC_BUCKET === env.R2_PRIVATE_BUCKET) throw new Error('Invalid R2 configuration');
  if (!suppliedClient && (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY)) throw new Error('Missing R2 credentials');
  const publicDelivery = env.R2_PUBLIC_DELIVERY ?? 'custom_domain';
  if (!['worker', 'custom_domain'].includes(publicDelivery)) throw new Error('Invalid public media delivery');
  if (publicDelivery === 'worker' && env.R2_PUBLIC_BASE_URL) {
    const base = new URL(env.R2_PUBLIC_BASE_URL);
    if (base.protocol !== 'https:' || base.port || base.pathname !== '/' || base.search || base.hash || base.username || base.password
      || !/^[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev$/.test(base.hostname)) throw new Error('Invalid public Worker URL');
  }
  const endpoint = `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const client = suppliedClient ?? new S3Client({
    endpoint, region: 'auto', forcePathStyle: true, maxAttempts: 2,
    credentials: { accessKeyId: env.R2_ACCESS_KEY_ID, secretAccessKey: env.R2_SECRET_ACCESS_KEY },
    requestChecksumCalculation: 'WHEN_REQUIRED', responseChecksumValidation: 'WHEN_REQUIRED',
  });
  const finalBucket = (bucket) => PUBLIC_BUCKETS.has(bucket) ? env.R2_PUBLIC_BUCKET : env.R2_PRIVATE_BUCKET;
  const checkBucket = (bucket) => {
    if (![env.R2_PUBLIC_BUCKET, env.R2_PRIVATE_BUCKET].includes(bucket)) throw new MediaError(503, 'media_location_unavailable');
  };
  async function read(location) {
    checkBucket(location.bucket);
    const response = await client.send(new GetObjectCommand({ Bucket: location.bucket, Key: location.path,
      ...(location.etag ? { IfMatch: location.etag } : {}) }), timeout());
    return { bytes: Buffer.from(await response.Body.transformToByteArray()), contentType: response.ContentType, etag: response.ETag };
  }
  async function putOnce(bucket, path, bytes, contentType, cacheControl) {
    checkBucket(bucket);
    try {
      const saved = await client.send(new PutObjectCommand({ Bucket: bucket, Key: path, Body: bytes,
        ContentLength: bytes.length, ContentType: contentType, CacheControl: cacheControl,
        Metadata: { sha256: digest(bytes) }, IfNoneMatch: '*' }), timeout());
      return saved.ETag;
    } catch (error) {
      if (!conflict(error)) throw error;
      const existing = await read({ bucket, path });
      if (existing.contentType !== contentType || digest(existing.bytes) !== digest(bytes)) throw new MediaError(409, 'media_identity_conflict');
      return existing.etag;
    }
  }
  async function store(item, bytes) {
    requireWriteWindow(item);
    const bucket = finalBucket(item.bucket);
    const path = `${item.bucket}/${item.path}`;
    const checksum = digest(bytes);
    const etag = await putOnce(bucket, path, bytes, item.content_type,
      PUBLIC_BUCKETS.has(item.bucket) ? 'public,max-age=86400,immutable' : 'private,no-store');
    if (!etag) throw new MediaError(503, 'media_identity_unavailable');
    // Read the destination bytes too; ETag is an opaque identity, never a checksum.
    const actual = await read({ bucket, path, etag });
    if (actual.bytes.length !== bytes.length || digest(actual.bytes) !== checksum || actual.contentType !== item.content_type) throw new MediaError(422, 'media_copy_mismatch');
    return { provider: 'r2', bucket, path, etag, checksum, bytes };
  }
  async function signUpload(item) {
    const seconds = Math.floor((new Date(item.upload_expires_at).getTime() - Date.now()) / 1000);
    if (seconds < 1 || seconds > 600) throw new MediaError(409, 'upload_expired');
    const headers = { 'Content-Type': item.content_type, 'Content-Length': String(item.byte_size), 'If-None-Match': '*' };
    const command = new PutObjectCommand({ Bucket: env.R2_PRIVATE_BUCKET, Key: `pending/${item.id}`,
      ContentType: item.content_type, ContentLength: Number(item.byte_size), IfNoneMatch: '*' });
    const url = await presign(client, command, { expiresIn: seconds,
      signableHeaders: new Set(['content-type', 'content-length', 'if-none-match']) });
    return { url, headers };
  }
  async function stage(item, bytes) {
    requireWriteWindow(item);
    validateBytes(bytes, item);
    await putOnce(env.R2_PRIVATE_BUCKET, `pending/${item.id}`, bytes, item.content_type, 'private,no-store');
  }
  async function finalize(item) {
    const location = { bucket: env.R2_PRIVATE_BUCKET, path: `pending/${item.id}` };
    const metadata = await client.send(new HeadObjectCommand({ Bucket: location.bucket, Key: location.path }), timeout());
    if (Number(metadata.ContentLength) !== Number(item.byte_size) || metadata.ContentType !== item.content_type) throw new MediaError(422, 'media_metadata_mismatch');
    const file = await read({ ...location, etag: metadata.ETag });
    validateBytes(file.bytes, item);
    return store(item, file.bytes);
  }
  async function signRead(location) {
    checkBucket(location.physical_bucket);
    const url = await presign(client, new GetObjectCommand({ Bucket: location.physical_bucket, Key: location.object_key,
      ResponseCacheControl: 'private,no-store' }), { expiresIn: 300 });
    return { url, expires_at: new Date(Date.now() + 300_000).toISOString() };
  }
  async function purge(paths) {
    if (!paths.length) return;
    if (publicDelivery === 'worker') return purgeWorkerImages(env, paths);
    if (!env.R2_PUBLIC_BASE_URL) return;
    if (!env.CLOUDFLARE_ZONE_ID || !env.CLOUDFLARE_CACHE_PURGE_TOKEN) throw new MediaError(503, 'media_cache_cleanup_pending');
    const base = new URL(env.R2_PUBLIC_BASE_URL);
    if (base.protocol !== 'https:' || base.pathname !== '/' || base.search || base.hash || base.username || base.password) throw new MediaError(503, 'media_location_unavailable');
    const response = await fetch(`https://api.cloudflare.com/client/v4/zones/${env.CLOUDFLARE_ZONE_ID}/purge_cache`, {
      method: 'POST', headers: { Authorization: `Bearer ${env.CLOUDFLARE_CACHE_PURGE_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ files: paths.map(path => `${base.origin}/${path.split('/').map(encodeURIComponent).join('/')}`) }), signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok || !(await response.json()).success) throw new MediaError(503, 'media_cache_cleanup_pending');
  }
  async function removeObject(job) {
    checkBucket(job.bucket);
    try {
      // Keys are immutable and never reused. Cleanup waits for upload/finalize fences in SQL.
      const metadata = await client.send(new HeadObjectCommand({ Bucket: job.bucket, Key: job.path }), timeout());
      if (job.etag && metadata.ETag !== job.etag) throw new MediaError(409, 'media_identity_conflict');
      await client.send(new DeleteObjectCommand({ Bucket: job.bucket, Key: job.path }), timeout());
    } catch (error) { if (!missing(error)) throw error; }
  }
  async function remove(job) {
    await removeObject(job);
    if (job.bucket === env.R2_PUBLIC_BUCKET) await purge([job.path]);
  }
  async function removeBatch(jobs) {
    const results = new Map();
    const publicJobs = [];
    for (const job of jobs) {
      try {
        await removeObject(job);
        results.set(job.id, true);
        if (job.bucket === env.R2_PUBLIC_BUCKET) publicJobs.push(job);
      } catch { results.set(job.id, false); }
    }
    try { await purge(publicJobs.map(job => job.path)); }
    catch { publicJobs.forEach(job => results.set(job.id, false)); }
    return results;
  }
  return { signUpload, finalize, signRead, remove, removeBatch, read, stage, store, finalBucket, pendingBucket: env.R2_PRIVATE_BUCKET };
}
