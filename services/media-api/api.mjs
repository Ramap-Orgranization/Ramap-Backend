import { MediaError, UUID, validateImageRequest, secretMatches, validateBytes } from './policy.mjs';
import { rpc } from './supabase.mjs';

export function createMediaApi({ service, authenticate, internalKey, r2, legacyCleanup }) {
  function gateway(provider) {
    const target = provider === 'r2' ? r2 : null;
    if (!target) throw new MediaError(503, 'media_provider_unavailable');
    return target;
  }
  const uploadProvider = (item) => item.upload_provider ?? item.provider;
  function r2Location(item) {
    return item.locations?.find((location) => location.provider === 'r2' && location.verified && !location.deleted);
  }
  async function registerTarget(item) {
    if (item.required_providers?.length) throw new MediaError(409, 'upload_unavailable');
    const storage = gateway(uploadProvider(item));
    await rpc(service, 'register_media_targets_v2', { p_id: item.id, p_targets: [
      { provider: 'r2', bucket: storage.finalBucket(item.bucket), pending_bucket: storage.pendingBucket },
    ] });
  }
  async function cleanup(mediaId = null, userId = null) {
    const jobs = userId === null
      ? await rpc(service, 'claim_media_cleanup', { p_id: mediaId, p_limit: 100 })
      : await rpc(service, 'claim_account_media_cleanup', { p_user_id: userId, p_limit: 100 });
    let failed = false;
    const directR2Jobs = jobs.filter(job => job.provider === 'r2' && !job.path.startsWith('pending/'));
    const r2Results = r2?.removeBatch && directR2Jobs.length ? await r2.removeBatch(directR2Jobs) : null;
    for (const job of jobs) {
      let success = false;
      try {
        if (r2Results?.has(job.id)) {
          if (!r2Results.get(job.id)) throw new MediaError(503, 'media_cache_cleanup_pending');
        } else if (job.provider === 'supabase') {
          const { error } = await service.storage.from(job.bucket).remove([job.path]);
          if (error) throw error;
        } else if (job.provider === 'gcs') {
          if (!legacyCleanup) throw new MediaError(503, 'media_provider_unavailable');
          await legacyCleanup.remove(job);
        } else {
          const storage = gateway(job.provider);
          await storage.remove(job);
          if (job.path.startsWith('pending/')) {
            const item = await rpc(service, 'fetch_service_media', { p_id: job.media_id });
            if (item && item.state !== 'ready') await storage.remove({ bucket: storage.finalBucket(item.bucket), path: `${item.bucket}/${item.path}` });
          }
        }
        success = true;
      } catch { failed = true; }
      await rpc(service, 'finish_media_cleanup', { p_id: job.id, p_success: success });
    }
    if (failed) throw new MediaError(503, 'media_cleanup_pending');
    return jobs.length;
  }
  async function resolve(client, images, internal) {
    if (!Array.isArray(images) || images.length > 64) throw new MediaError(400, 'invalid_media_batch');
    images.forEach(validateImageRequest);
    let locations;
    if (internal) {
      locations = [];
      for (const image of images) {
        const item = await rpc(service, 'fetch_service_media', { p_bucket: image.bucket, p_path: image.path });
        if (item?.state !== 'ready') continue;
        const location = r2Location(item);
        if (location) locations.push({ bucket: image.bucket, path: image.path, provider: location.provider,
          physical_bucket: location.bucket, object_key: location.path, etag: location.etag });
      }
    } else locations = await rpc(client, 'resolve_media_locations_v2', { p_images: images });
    return await Promise.all(locations.filter(({ provider }) => provider === 'r2').map(async (location) => ({
      bucket: location.bucket, path: location.path, ...await gateway('r2').signRead(location),
    })));
  }
  async function prepare(client, body, internal) {
    validateImageRequest(body);
    if (!Number.isSafeInteger(body.byte_size) || body.byte_size < 1 || !['image/jpeg', 'image/png', 'image/webp'].includes(body.content_type)) throw new MediaError(400, 'invalid_media');
    const name = internal ? 'prepare_service_media_v2' : 'prepare_media_upload_v2';
    const item = await rpc(client, name, { p_bucket: body.bucket, p_path: body.path, p_content_type: body.content_type, p_byte_size: body.byte_size });
    if (item.provider === 'supabase') throw new MediaError(503, 'media_provider_unavailable');
    const provider = uploadProvider(item);
    if (item.state === 'ready') return { provider, id: item.id, ready: true };
    await registerTarget(item);
    return { provider, id: item.id, ready: false, ...await gateway(provider).signUpload(item) };
  }
  async function finalize(client, body, internal) {
    if (!UUID.test(body.id ?? '')) throw new MediaError(400, 'invalid_upload');
    let item = await rpc(client, internal ? 'fetch_service_media' : 'fetch_media_upload', { p_id: body.id });
    if (!item || !['ready', 'pending'].includes(item.state)) throw new MediaError(409, 'upload_unavailable');
    if (item.state === 'ready') return { ready: true };
    item = await rpc(service, 'begin_media_finalization', { p_id: item.id });
    if (item.required_providers?.length) throw new MediaError(409, 'upload_unavailable');
    const provider = uploadProvider(item);
    const verified = await gateway(provider).finalize(item);
    await rpc(service, 'complete_media_upload_v2', { p_id: item.id,
      p_locations: [{ provider, bucket: verified.bucket, path: verified.path, etag: verified.etag }],
      p_size: item.byte_size, p_type: item.content_type, p_checksum: verified.checksum });
    return { ready: true };
  }
  async function preserveAccountReviewPhotos(userId) {
    const bucket = 'shop-review-images';
    const storage = gateway('r2');
    const parameters = { p_user_id: userId };
    for (let batch = 0; batch < 4; batch++) {
      const copies = await rpc(service, 'list_account_review_photo_copies', parameters);
      if (!copies.length) return;
      for (let offset = 0; offset < copies.length; offset += 6) {
        await Promise.all(copies.slice(offset, offset + 6).map(async (photo) => {
          const destination = await rpc(service, 'reserve_withdrawn_review_photo', {
            ...parameters, p_source_path: photo.source_path, p_destination_path: photo.destination_path,
            p_bucket: storage.finalBucket(bucket),
          });
          if (destination.state === 'ready') return;
          const source = await rpc(service, 'fetch_service_media', { p_bucket: bucket, p_path: photo.source_path });
          const location = source?.state === 'ready' && r2Location(source);
          if (!location) throw new MediaError(503, 'review_photo_copy_pending');
          const file = await storage.read(location);
          if (file.contentType !== destination.content_type || validateBytes(file.bytes, destination) !== destination.checksum) {
            throw new MediaError(409, 'review_photo_source_changed');
          }
          const saved = await storage.store(destination, file.bytes);
          await rpc(service, 'finish_withdrawn_review_photo', {
            ...parameters, p_id: destination.id, p_expires_at: destination.upload_expires_at,
            p_etag: saved.etag, p_checksum: saved.checksum,
          });
        }));
      }
    }
  }
  async function backfill(body) {
    validateImageRequest(body);
    const provider = body.provider;
    if (provider !== 'r2') throw new MediaError(400, 'invalid_provider');
    const storage = gateway(provider);
    const source = body.source;
    if (!source || source.provider !== 'supabase') throw new MediaError(400, 'invalid_source');
    const eligibility = await rpc(service, 'media_copy_eligibility', { p_bucket: body.bucket, p_path: body.path });
    if (eligibility?.needed === false) return { copied: false, skipped: true, reason: eligibility.reason };
    if (eligibility?.needed !== true) throw new MediaError(503, 'media_copy_scope_unavailable');
    const id = await rpc(service, 'reserve_media_copy_v2', { p_bucket: body.bucket, p_path: body.path, p_source: source });
    if (!id) return { copied: false, skipped: true, reason: 'reference_changed' };
    await rpc(service, 'register_media_copy_target_v2', { p_id: id, p_provider: provider, p_bucket: storage.finalBucket(body.bucket) });
    const item = await rpc(service, 'fetch_service_media', { p_id: id });
    const { data, error } = await service.storage.from(source.bucket).download(source.path);
    if (error || !data) throw new MediaError(404, 'media_source_unavailable');
    const file = { bytes: Buffer.from(await data.arrayBuffer()), contentType: data.type };
    if (file.bytes.length !== Number(item.byte_size) || file.contentType !== item.content_type) throw new MediaError(409, 'media_source_changed');
    const saved = await storage.store(item, file.bytes);
    await rpc(service, 'record_media_copy_v2', { p_id: id, p_source: source,
      p_destination: { provider, bucket: saved.bucket, path: saved.path, etag: saved.etag },
      p_checksum: saved.checksum, p_size: file.bytes.length, p_type: file.contentType });
    return { copied: true, sha256: saved.checksum, byte_size: file.bytes.length };
  }
  async function copy(body) {
    validateImageRequest(body.source);
    validateImageRequest(body);
    const source = await rpc(service, 'fetch_service_media', { p_bucket: body.source.bucket, p_path: body.source.path });
    if (source?.state !== 'ready') throw new MediaError(404, 'media_source_unavailable');
    const location = r2Location(source);
    if (!location) throw new MediaError(404, 'media_source_unavailable');
    const file = await gateway('r2').read(location);
    const item = await rpc(service, 'prepare_service_media_v2', { p_bucket: body.bucket, p_path: body.path, p_content_type: file.contentType, p_byte_size: file.bytes.length });
    if (item.provider === 'supabase') {
      throw new MediaError(503, 'media_provider_unavailable');
    }
    if (item.state !== 'ready') {
      await registerTarget(item);
      await gateway(uploadProvider(item)).stage(item, file.bytes);
      await finalize(service, { id: item.id }, true);
    }
    return { copied: true };
  }
  async function handle(request) {
    const pathname = new URL(request.url).pathname;
    if (pathname === '/health' && request.method === 'GET') return Response.json({ healthy: true });
    if (request.method !== 'POST') return Response.json({ code: 'method_not_allowed' }, { status: 405 });
    try {
      const route = pathname.match(/^\/(internal\/)?v2\/(.+)$/);
      if (!route) throw new MediaError(404, 'not_found');
      const internal = route[1] !== undefined;
      const action = route[2];
      const token = request.headers.get('authorization')?.match(/^Bearer\s+(.+)$/i)?.[1];
      if (internal && !secretMatches(token, internalKey)) throw new MediaError(401, 'authentication_required');
      const { client, userId } = internal ? { client: service, userId: null } : await authenticate(token);
      if (!internal && action !== 'resolve' && !userId) throw new MediaError(401, 'authentication_required');
      const body = await request.json();
      let result;
      if (action === 'resolve') result = await resolve(client, body.images, internal);
      else if (action === 'prepare') result = await prepare(client, body, internal);
      else if (action === 'finalize') result = await finalize(client, body, internal);
      else if (action === 'delete') {
        validateImageRequest(body);
        const id = await rpc(client, internal ? 'delete_service_media' : 'delete_media_object', { p_bucket: body.bucket, p_path: body.path });
        if (id) await cleanup(id);
        else {
          const { error } = await client.storage.from(body.bucket).remove([body.path]);
          if (error) throw new MediaError(403, 'media_delete_rejected');
        }
        result = { deleted: true };
      } else if (action === 'account/cleanup' && !internal) {
        await preserveAccountReviewPhotos(userId);
        await rpc(service, 'prepare_account_media_cleanup', { p_user_id: userId });
        for (let batch = 0; batch < 20 && await cleanup(null, userId); batch++) { /* Bounded; the check below gates Auth deletion. */ }
        if (await rpc(service, 'account_has_external_media', { p_user_id: userId })) throw new MediaError(503, 'media_cleanup_pending');
        result = { deleted: true };
      } else if (action === 'cleanup' && internal) result = { processed: await cleanup() };
      else if (action === 'copy' && internal) result = await copy(body);
      else if (action === 'backfill' && internal) result = await backfill(body);
      else throw new MediaError(404, 'not_found');
      return Response.json(result, { headers: { 'Cache-Control': 'no-store' } });
    } catch (error) {
      return Response.json({ code: error instanceof MediaError ? error.code : 'media_unavailable' },
        { status: error instanceof MediaError ? error.status : 503, headers: { 'Cache-Control': 'no-store' } });
    }
  }
  return { handle, cleanup };
}
