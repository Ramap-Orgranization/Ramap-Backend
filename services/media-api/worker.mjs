import { createMediaApi } from './api.mjs';
import { createSupabaseGateway } from './supabase.mjs';
import { createR2Gateway } from './r2.mjs';
import { createLegacyGcsCleanup } from './legacy-cleanup.mjs';

const api = createMediaApi({ ...createSupabaseGateway(process.env), r2: createR2Gateway(process.env), legacyCleanup: createLegacyGcsCleanup(process.env) });
let processed = 0;
for (let batch = 0; batch < 20; batch++) {
  const count = await api.cleanup();
  processed += count;
  if (!count) break;
}
console.log(JSON.stringify({ processed }));
