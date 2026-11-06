import { createHmac } from 'node:crypto';
import { MediaError } from './policy.mjs';

export async function purgeWorkerImages(env, paths) {
  if (!env.R2_PUBLIC_BASE_URL || !env.R2_WORKER_PURGE_SECRET) throw new MediaError(503, 'media_cache_cleanup_pending');
  const base = new URL(env.R2_PUBLIC_BASE_URL);
  if (base.protocol !== 'https:' || !/^[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev$/.test(base.hostname)
    || base.pathname !== '/' || base.port || base.username || base.password || base.search || base.hash) throw new MediaError(503, 'media_cache_cleanup_pending');
  const unique = [...new Set(paths)];
  for (let start = 0; start < unique.length; start += 100) {
    const batch = unique.slice(start, start + 100);
    const body = JSON.stringify({ paths: batch });
    const timestamp = String(Math.floor(Date.now() / 1000));
    const signature = createHmac('sha256', env.R2_WORKER_PURGE_SECRET).update(`${timestamp}\n${body}`).digest('hex');
    const response = await fetch(`${base.origin}/internal/cache/purge`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Ramap-Purge-Timestamp': timestamp, 'X-Ramap-Purge-Signature': signature },
      body, signal: AbortSignal.timeout(15_000), redirect: 'error',
    });
    if (!response.ok || !(await response.json()).success) throw new MediaError(503, 'media_cache_cleanup_pending');
    // An accepted purge is not proof of eviction. Confirm absence before finishing cleanup.
    for (let index = 0; index < batch.length; index += 8) {
      await Promise.all(batch.slice(index, index + 8).map(async path => {
        const result = await fetch(`${base.origin}/${path.split('/').map(encodeURIComponent).join('/')}`, {
          method: 'HEAD', signal: AbortSignal.timeout(10_000), redirect: 'error',
        });
        if (result.status !== 404) throw new MediaError(503, 'media_cache_cleanup_pending');
      }));
    }
  }
}
