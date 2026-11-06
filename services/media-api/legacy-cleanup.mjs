import { MediaError } from './policy.mjs';

const missing = (error) => error.response?.status === 404;

// Retired GCS objects are never upload/read providers; this adapter only drains
// registered generations from explicitly configured historical buckets.
export function createLegacyGcsCleanup(env, suppliedAuth) {
  const buckets = new Set((env.LEGACY_GCS_CLEANUP_BUCKETS ?? '').split(';').filter(Boolean));
  if (!buckets.size) return null;
  if ([...buckets].some((bucket) => !/^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$/.test(bucket))) throw new Error('Invalid retired media buckets');
  let auth = suppliedAuth;
  async function remove(job) {
    if (!buckets.has(job.bucket)) throw new MediaError(503, 'media_location_unavailable');
    if (typeof job.path !== 'string' || !job.path || !/^[1-9][0-9]*$/.test(job.generation ?? '')) throw new MediaError(503, 'media_identity_unavailable');
    if (!auth) {
      const { GoogleAuth } = await import('google-auth-library');
      auth ??= new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/devstorage.read_write'] });
    }
    const url = `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(job.bucket)}/o/${encodeURIComponent(job.path)}`;
    const options = { url, timeout: 10_000, retry: false };
    try {
      await auth.request({ ...options, method: 'DELETE', params: { generation: job.generation, ifGenerationMatch: job.generation } });
    } catch (error) {
      if (!missing(error)) throw error;
    }
    try {
      await auth.request({ ...options, method: 'GET', params: { generation: job.generation, softDeleted: true, fields: 'generation,hardDeleteTime' } });
    } catch (error) {
      if (missing(error)) return;
      throw error;
    }
    // A soft-deleted object still exists until its provider retention expires.
    throw new MediaError(503, 'media_cleanup_pending');
  }
  return { remove };
}
