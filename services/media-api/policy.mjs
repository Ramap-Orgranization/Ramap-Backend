import { createHash, timingSafeEqual } from 'node:crypto';

export const PUBLIC_BUCKETS = new Set(['shop-profile-images', 'menu-images', 'event-images']);
export const PRIVATE_BUCKETS = new Set(['shop-review-images', 'profile-avatars', 'news-report-evidence']);
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export class MediaError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}

export function validateImageRequest(input) {
  if (!input || ![...PUBLIC_BUCKETS, ...PRIVATE_BUCKETS].includes(input.bucket) || typeof input.path !== 'string'
    || !input.path || input.path.length > 512 || input.path.startsWith('/') || input.path.includes('..')
    || /[\\%?#\x00-\x1f]/.test(input.path)) throw new MediaError(400, 'invalid_media');
  return input;
}

export function digest(bytes) { return createHash('sha256').update(bytes).digest('hex'); }

export function validateBytes(bytes, item) {
  if (bytes.length !== Number(item.byte_size)) throw new MediaError(422, 'media_size_mismatch');
  const jpeg = bytes.length >= 3 && bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]));
  const png = bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const webp = bytes.length >= 12 && bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP';
  if (!({ 'image/jpeg': jpeg, 'image/png': png, 'image/webp': webp })[item.content_type]) throw new MediaError(422, 'media_type_mismatch');
  return digest(bytes);
}

export function secretMatches(received, expected) {
  if (!received || !expected) return false;
  const actualBytes = Buffer.from(received);
  const expectedBytes = Buffer.from(expected);
  return actualBytes.length === expectedBytes.length && timingSafeEqual(actualBytes, expectedBytes);
}

// Leave enough time for one bounded write before the SQL cleanup fence.
export function requireWriteWindow(item) {
  const expiry = item.finalizing_until ?? item.upload_expires_at;
  if (expiry && new Date(expiry).getTime() < Date.now() + 60_000) throw new MediaError(409, 'media_write_window_expired');
}
