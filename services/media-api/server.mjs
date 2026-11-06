import { createServer } from 'node:http';
import { createMediaApi } from './api.mjs';
import { createSupabaseGateway } from './supabase.mjs';
import { createR2Gateway } from './r2.mjs';
import { createLegacyGcsCleanup } from './legacy-cleanup.mjs';

const api = createMediaApi({ ...createSupabaseGateway(process.env), r2: createR2Gateway(process.env), legacyCleanup: createLegacyGcsCleanup(process.env) });
const MAX_BODY_BYTES = 64 * 1024;
createServer(async (incoming, outgoing) => {
  try {
    const chunks = [];
    let size = 0;
    for await (const chunk of incoming) {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) { outgoing.writeHead(413).end(); incoming.destroy(); return; }
      chunks.push(chunk);
    }
    const response = await api.handle(new Request(`https://media.invalid${incoming.url}`, {
      method: incoming.method, headers: incoming.headers,
      body: ['GET', 'HEAD'].includes(incoming.method) ? undefined : Buffer.concat(chunks),
    }));
    outgoing.writeHead(response.status, Object.fromEntries(response.headers));
    outgoing.end(Buffer.from(await response.arrayBuffer()));
  } catch { outgoing.writeHead(503).end('{"code":"media_unavailable"}'); }
}).listen(Number(process.env.PORT ?? 8080), '0.0.0.0');
