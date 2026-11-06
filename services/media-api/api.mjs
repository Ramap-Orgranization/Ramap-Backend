import { MediaError, UUID, validateImageRequest, secretMatches, digest } from './policy.mjs';
import { rpc } from './supabase.mjs';

export function createMediaApi({ service, authenticate, internalKey, r2, legacyCleanup }) {
  function gateway(provider) {
    const target = provider === 'r2' ? r2 : null;
    if (!target) throw new MediaError(503, 'media_provider_unavailable');
    return target;
  }
  const uploadProvider = (item) => item.upload_provider ?? item.provider;
  const requirements = (item) => item.required_providers ?? (item.legacy_required ? ['supabase'] : []);
  const externalProviders = (item) => [...new Set([uploadProvider(item), ...requirements(item)])].filter((p) => p !== 'supabase');
  function selectLocation(item, v2 = true) {
    return (v2 ? ['r2', 'supabase'] : ['supabase'])
      .map((provider) => item.locations?.find((l) => l.provider === provider && l.verified && !l.deleted)).find(Boolean);
  }
  async function registerTargets(item) {
    const targets = externalProviders(item).map((provider) => {
      const storage = gateway(provider);
      return { provider, bucket: storage.finalBucket(item.bucket), pending_bucket: storage.pendingBucket };
    });
    await rpc(service, 'register_media_targets_v2', { p_id: item.id, p_targets: targets });
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
  async function resolve(client, images, internal, v2) {
    if (!Array.isArray(images) || images.length > 64) throw new MediaError(400, 'invalid_media_batch');
    images.forEach(validateImageRequest);
    let locations;
    if (internal) {
      locations = [];
      for (const image of images) {
        const item = await rpc(service, 'fetch_service_media', { p_bucket: image.bucket, p_path: image.path });
        if (item?.state !== 'ready') continue;
        const location = selectLocation(item, v2);
        if (location) locations.push({ bucket: image.bucket, path: image.path, provider: location.provider,
          physical_bucket: location.bucket, object_key: location.path, etag: location.etag });
      }
    } else locations = await rpc(client, v2 ? 'resolve_media_locations_v2' : 'resolve_media_locations', { p_images: images });
    const results = locations.map(({ bucket, path }) => ({ bucket, path, url: null }));
    const legacyBuckets = new Map();
    const external = [];
    for (const [index, location] of locations.entries()) {
      if (location.provider === 'supabase') {
        if (!legacyBuckets.has(location.physical_bucket)) legacyBuckets.set(location.physical_bucket, []);
        legacyBuckets.get(location.physical_bucket).push({ index, location });
      } else {
        if (!v2) throw new MediaError(503, 'media_provider_unavailable');
        external.push({ index, location });
      }
    }
    await Promise.all([
      ...external.map(async ({ index, location }) => {
        results[index] = { ...results[index], ...await gateway(location.provider).signRead(location) };
      }),
      ...[...legacyBuckets].map(async ([bucket, entries]) => {
        const paths = [...new Set(entries.map(({ location }) => location.object_key))];
        const expiresAt = new Date(Date.now() + 300_000).toISOString();
        const { data, error } = await (internal ? service : client).storage.from(bucket).createSignedUrls(paths, 300);
        if (error) return;
        const signed = new Map();
        for (const row of data ?? []) {
          // A duplicate or missing result must not be matched by response position.
          signed.set(row.path, signed.has(row.path) ? null : row);
        }
        for (const { index, location } of entries) {
          const row = signed.get(location.object_key);
          if (row?.signedUrl && !row.error) results[index] = { ...results[index], url: row.signedUrl, expires_at: expiresAt };
        }
      }),
    ]);
    return results;
  }
  async function prepare(client, body, internal, v2) {
    validateImageRequest(body);
    if (!Number.isSafeInteger(body.byte_size) || body.byte_size < 1 || !['image/jpeg', 'image/png', 'image/webp'].includes(body.content_type)) throw new MediaError(400, 'invalid_media');
    const name = (internal ? 'prepare_service_media' : 'prepare_media_upload') + (v2 ? '_v2' : '');
    const item = await rpc(client, name, { p_bucket: body.bucket, p_path: body.path, p_content_type: body.content_type, p_byte_size: body.byte_size });
    if (item.provider === 'supabase') return { provider: 'supabase' };
    const provider = uploadProvider(item);
    if (item.state === 'ready') return { provider, id: item.id, ready: true };
    if (!v2) throw new MediaError(409, 'upload_requires_v2');
    await registerTargets(item);
    return { provider, id: item.id, ready: false, ...await gateway(provider).signUpload(item) };
  }
  async function mirrorLegacy(client, item, verified) {
    const { error } = await client.storage.from(item.bucket).upload(item.path, verified.bytes, { contentType: item.content_type, upsert: false });
    if (!error) return;
    if (!['409', 'Duplicate'].includes(String(error.statusCode ?? error.error))) throw new MediaError(503, 'legacy_mirror_pending');
    const { data, error: readError } = await service.storage.from(item.bucket).download(item.path);
    if (readError || !data || digest(Buffer.from(await data.arrayBuffer())) !== verified.checksum) throw new MediaError(409, 'legacy_mirror_conflict');
  }
  async function finalize(client, body, internal, v2) {
    if (!UUID.test(body.id ?? '')) throw new MediaError(400, 'invalid_upload');
    let item = await rpc(client, internal ? 'fetch_service_media' : 'fetch_media_upload', { p_id: body.id });
    if (!item || !['ready', 'pending'].includes(item.state)) throw new MediaError(409, 'upload_unavailable');
    if (item.state === 'ready') return { ready: true };
    if (!v2) throw new MediaError(409, 'upload_requires_v2');
    item = await rpc(service, 'begin_media_finalization', { p_id: item.id });
    const provider = uploadProvider(item);
    const verified = await gateway(provider).finalize(item);
    const locations = [{ provider, ...verified }];
    for (const mirror of requirements(item)) {
      if (mirror === 'supabase') await mirrorLegacy(internal ? service : client, item, verified);
      else if (mirror !== provider) locations.push({ provider: mirror, ...await gateway(mirror).store(item, verified.bytes) });
    }
    await rpc(service, 'complete_media_upload_v2', { p_id: item.id,
      p_locations: locations.map(({ provider, bucket, path, etag }) => ({ provider, bucket, path, etag })),
      p_size: item.byte_size, p_type: item.content_type, p_checksum: verified.checksum });
    return { ready: true };
  }
  async function readSource(source) {
    if (source.provider !== 'supabase') return gateway(source.provider).read(source);
    const { data, error } = await service.storage.from(source.bucket).download(source.path);
    if (error || !data) throw new MediaError(404, 'media_source_unavailable');
    return { bytes: Buffer.from(await data.arrayBuffer()), contentType: data.type };
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
    const file = await readSource(source);
    if (file.bytes.length !== Number(item.byte_size) || file.contentType !== item.content_type) throw new MediaError(409, 'media_source_changed');
    const saved = await storage.store(item, file.bytes);
    await rpc(service, 'record_media_copy_v2', { p_id: id, p_source: source,
      p_destination: { provider, bucket: saved.bucket, path: saved.path, etag: saved.etag },
      p_checksum: saved.checksum, p_size: file.bytes.length, p_type: file.contentType });
    return { copied: true, sha256: saved.checksum, byte_size: file.bytes.length };
  }
  async function copy(body, v2) {
    validateImageRequest(body.source);
    validateImageRequest(body);
    const source = await rpc(service, 'fetch_service_media', { p_bucket: body.source.bucket, p_path: body.source.path });
    if (source?.state !== 'ready') throw new MediaError(404, 'media_source_unavailable');
    const location = selectLocation(source);
    if (!location) throw new MediaError(404, 'media_source_unavailable');
    const file = await readSource(location);
    const name = v2 ? 'prepare_service_media_v2' : 'prepare_service_media';
    const item = await rpc(service, name, { p_bucket: body.bucket, p_path: body.path, p_content_type: file.contentType, p_byte_size: file.bytes.length });
    if (item.provider === 'supabase') {
      const { error } = await service.storage.from(body.bucket).upload(body.path, file.bytes, { contentType: file.contentType, upsert: false });
      if (error) throw new MediaError(503, 'media_copy_failed');
    } else if (item.state !== 'ready') {
      await registerTargets(item);
      await gateway(uploadProvider(item)).stage(item, file.bytes);
      await finalize(service, { id: item.id }, true, v2);
    }
    return { copied: true };
  }
  async function handle(request) {
    const pathname = new URL(request.url).pathname;
    if (pathname === '/health' && request.method === 'GET') return Response.json({ healthy: true });
    if (request.method !== 'POST') return Response.json({ code: 'method_not_allowed' }, { status: 405 });
    try {
      const route = pathname.match(/^\/(v1|v2|internal)(?:\/(v2))?\/(.+)$/);
      if (!route || (route[2] && route[1] !== 'internal')) throw new MediaError(404, 'not_found');
      const internal = route[1] === 'internal';
      const v2 = route[1] === 'v2' || route[2] === 'v2';
      const action = route[3];
      const token = request.headers.get('authorization')?.match(/^Bearer\s+(.+)$/i)?.[1];
      if (internal && !secretMatches(token, internalKey)) throw new MediaError(401, 'authentication_required');
      const { client, userId } = internal ? { client: service, userId: null } : await authenticate(token);
      if (!internal && action !== 'resolve' && !userId) throw new MediaError(401, 'authentication_required');
      const body = await request.json();
      let result;
      if (action === 'resolve') result = await resolve(client, body.images, internal, v2);
      else if (action === 'prepare') result = await prepare(client, body, internal, v2);
      else if (action === 'finalize') result = await finalize(client, body, internal, v2);
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
        await rpc(service, 'prepare_account_media_cleanup', { p_user_id: userId });
        for (let batch = 0; batch < 20 && await cleanup(null, userId); batch++) { /* Bounded; the check below gates Auth deletion. */ }
        if (await rpc(service, 'account_has_external_media', { p_user_id: userId })) throw new MediaError(503, 'media_cleanup_pending');
        result = { deleted: true };
      } else if (action === 'cleanup' && internal) result = { processed: await cleanup() };
      else if (action === 'copy' && internal) result = await copy(body, v2);
      else if (action === 'backfill' && internal && v2) result = await backfill(body);
      else throw new MediaError(404, 'not_found');
      return Response.json(result, { headers: { 'Cache-Control': 'no-store' } });
    } catch (error) {
      return Response.json({ code: error instanceof MediaError ? error.code : 'media_unavailable' },
        { status: error instanceof MediaError ? error.status : 503, headers: { 'Cache-Control': 'no-store' } });
    }
  }
  return { handle, cleanup };
}
