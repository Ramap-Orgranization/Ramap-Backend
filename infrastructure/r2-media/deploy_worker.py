#!/usr/bin/env python3
"""공개 사진 Worker를 배포한다. 기본은 로컬 bundle 검증만 하며 도메인을 구매하지 않는다."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from provision import validate

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / 'services/public-media-worker'


def worker_configuration(config):
    validate(config)
    if config.get('public_delivery', 'worker') != 'worker':
        raise ValueError('Worker delivery mode is required')
    return {'name': config.get('public_worker_name', 'ramap-images'), 'account_id': config['r2_account_id'],
            'main': str(WORKER / 'src.mjs'), 'compatibility_date': '2026-11-01', 'workers_dev': True,
            'preview_urls': False, 'observability': {'enabled': True},
            # Keep the purge API available even when response caching is disabled by headers.
            'cache': {'enabled': True, 'cross_version_cache': False},
            'vars': {'EDGE_CACHE_ENABLED': str(config.get('public_cache_enabled', False)).lower()},
            'r2_buckets': [{'binding': 'PUBLIC_IMAGES', 'bucket_name': config['r2_public_bucket']}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--output', type=Path, help='실제 workers.dev 주소가 포함된 로컬 연결 설정')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    settings = worker_configuration(config)
    executable = WORKER / 'node_modules/.bin/wrangler'
    if not executable.exists():
        parser.error('Run npm --prefix services/public-media-worker ci first')
    if args.apply and (not args.output or not args.output.is_absolute() or ROOT in args.output.resolve().parents):
        parser.error('--apply requires an absolute --output path outside Git')
    # Configuration contains no credentials. Wrangler reads a local OAuth session or environment API token.
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', prefix='ramap-worker-') as temporary:
        json.dump(settings, temporary)
        temporary.flush()
        command = [str(executable), 'deploy', '--config', temporary.name]
        if not args.apply:
            command.append('--dry-run')
        result = subprocess.run(command, cwd=WORKER, capture_output=True, text=True,
                                env={**os.environ, 'WRANGLER_SEND_METRICS': 'false'})
    if result.returncode:
        raise SystemExit('Worker deployment failed; verify local Cloudflare login and R2 activation')
    if not args.apply:
        print(json.dumps({'bundle_verified': True, 'deployed': False, 'domain_purchase': False, 'worker': settings['name']}))
        return
    urls = re.findall(r'https://' + re.escape(settings['name']) + r'\.[a-z0-9-]+\.workers\.dev\b', result.stdout)
    if not urls:
        raise SystemExit('Worker uploaded, but no public URL was returned. Inspect its Domains & Routes before continuing')
    config.update({'public_delivery': 'worker', 'r2_public_base_url': urls[-1]})
    validate(config)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(config, indent=2) + '\n')
    print(json.dumps({'deployed': True, 'public_url': urls[-1], 'domain_purchase': False}))


if __name__ == '__main__':
    main()
