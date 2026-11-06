import { createClient } from '@supabase/supabase-js';
import { MediaError } from './policy.mjs';

export function createSupabaseGateway(env) {
  for (const name of ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY']) {
    if (!env[name]) throw new Error(`Missing ${name}`);
  }
  const options = { auth: { persistSession: false, autoRefreshToken: false } };
  const service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, options);
  function userClient(token) {
    return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
      ...options, global: token ? { headers: { Authorization: `Bearer ${token}` } } : {},
    });
  }
  async function authenticate(token) {
    const client = userClient(token);
    if (!token) return { client, userId: null };
    const { data, error } = await client.auth.getUser(token);
    if (error || !data.user) throw new MediaError(401, 'authentication_required');
    return { client, userId: data.user.id };
  }
  return { service, authenticate, internalKey: env.SUPABASE_SERVICE_ROLE_KEY };
}

export async function rpc(client, name, parameters = {}) {
  const { data, error } = await client.rpc(name, parameters);
  if (error) {
    const status = error.code === '42501' ? 403 : error.code === 'PT429' ? 429 : 409;
    throw new MediaError(status, 'media_request_rejected');
  }
  return data;
}
