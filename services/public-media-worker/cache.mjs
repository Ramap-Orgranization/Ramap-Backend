export const PURGE_PATH = '/internal/cache/purge';
const MAX_BODY_BYTES = 65_536;
const MAX_PATHS = 100;
const MAX_CLOCK_SKEW_SECONDS = 60;
const encoder = new TextEncoder();

export async function cacheTag(key) {
  const hash = await crypto.subtle.digest('SHA-256', encoder.encode(key));
  return `media-${Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}

function reply(status, success = false) {
  return Response.json({ success }, { status, headers: {
    'Cache-Control': 'no-store', 'CDN-Cache-Control': 'no-store', 'Cloudflare-CDN-Cache-Control': 'no-store',
  } });
}

async function boundedBody(request) {
  if (Number(request.headers.get('Content-Length') ?? 0) > MAX_BODY_BYTES) return null;
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY_BYTES) { await reader.cancel(); return null; }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

export async function purgeCache(request, env, ctx, parseKey) {
  if (request.method !== 'POST') return reply(405);
  const timestamp = request.headers.get('X-Ramap-Purge-Timestamp') ?? '';
  const signature = request.headers.get('X-Ramap-Purge-Signature') ?? '';
  if (!/^\d{10}$/.test(timestamp) || !/^[a-f0-9]{64}$/.test(signature)
    || !env.PUBLIC_CACHE_PURGE_SECRET || Math.abs(Date.now() / 1000 - Number(timestamp)) > MAX_CLOCK_SKEW_SECONDS) return reply(401);
  const body = await boundedBody(request);
  if (body === null) return reply(413);
  const text = new TextDecoder().decode(body);
  const key = await crypto.subtle.importKey('raw', encoder.encode(env.PUBLIC_CACHE_PURGE_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  const signatureBytes = Uint8Array.from(signature.match(/../g), (hex) => Number.parseInt(hex, 16));
  if (!await crypto.subtle.verify('HMAC', key, signatureBytes, encoder.encode(`${timestamp}\n${text}`))) return reply(401);
  let paths;
  try { paths = JSON.parse(text).paths; } catch { return reply(400); }
  if (!Array.isArray(paths) || !paths.length || paths.length > MAX_PATHS) return reply(400);
  const keys = [];
  for (const path of paths) {
    if (typeof path !== 'string' || path.startsWith('/') || path.length > 600) return reply(400);
    const parsed = parseKey(new URL(`https://cache.invalid/${path.split('/').map(encodeURIComponent).join('/')}`));
    if (parsed !== path) return reply(400);
    keys.push(parsed);
  }
  try {
    const tags = await Promise.all([...new Set(keys)].map(cacheTag));
    const result = await ctx.cache.purge({ tags });
    return result.success ? reply(200, true) : reply(503);
  } catch { return reply(503); }
}
