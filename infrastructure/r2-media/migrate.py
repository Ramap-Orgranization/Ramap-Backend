#!/usr/bin/env python3
"""Supabase 사진을 R2에 복사하고 검증한다. 기본은 집계만 조회한다."""
import argparse
import json
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
from media_client import MediaService


class Migration(MediaService):
    def inventory(self):
        after = ''
        while True:
            rows = self.rpc('media_inventory_v2', {'p_after': after, 'p_limit': 500})
            yield from rows
            if len(rows) < 500:
                return
            after = rows[-1]['cursor']

    def copy(self, row):
        if not needed(row):
            return {'copied': False, 'skipped': True, 'reason': row['migration_reason']}
        if not row.get('legacy_updated_at'):
            raise ValueError('Verified Supabase copy source is required')
        source = {'provider': 'supabase', 'bucket': row['bucket'], 'path': row['path'], 'updated_at': row['legacy_updated_at']}
        endpoint = urllib.parse.urlsplit(self.config['media_api_url'])
        if endpoint.scheme != 'https' or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment:
            raise ValueError('Invalid media API endpoint')
        result = self.request('POST', self.config['media_api_url'].rstrip('/') + '/internal/v2/backfill',
                              json.dumps({'bucket': row['bucket'], 'path': row['path'], 'provider': 'r2', 'source': source}).encode(),
                              {'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json'})
        return {**json.loads(result), 'bucket': row['bucket'], 'path': row['path']}


def needed(row):
    if not isinstance(row.get('migration_needed'), bool) or not row.get('migration_reason'):
        raise ValueError('Apply the used-photo migration before copying')
    return row['migration_needed']


def copied(row):
    return any(l['provider'] == 'r2' and l['verified'] and not l['deleted'] for l in row['locations'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='deploy.py가 출력한 로컬 연결 설정')
    parser.add_argument('--copy', action='store_true')
    parser.add_argument('--manifest', type=Path)
    args = parser.parse_args()
    if args.copy and (not args.manifest or not args.manifest.is_absolute() or ROOT in args.manifest.resolve().parents):
        parser.error('--copy에는 Git 외부의 절대 경로 --manifest가 필요합니다')
    migration = Migration(json.loads(args.config.read_text()))
    rows = list(migration.inventory())
    selected = [r for r in rows if needed(r)]
    skipped = [r for r in rows if not needed(r)]
    pending = [r for r in selected if not copied(r)]
    print(json.dumps({'objects': len(rows), 'selected': len(selected), 'selected_bytes': sum(r['byte_size'] or 0 for r in selected),
                      'skipped': len(skipped), 'skip_reasons': dict(Counter(r['migration_reason'] for r in skipped)), 'uncopied': len(pending)}), flush=True)
    if not args.copy:
        return
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(args.manifest, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.fchmod(descriptor, 0o600)
    failed = 0
    def copy_result(row):
        try:
            return migration.copy(row)
        except Exception:
            return {'bucket': row['bucket'], 'path': row['path'], 'copied': False}
    with os.fdopen(descriptor, 'a') as manifest, ThreadPoolExecutor(max_workers=4) as pool:
        for result in pool.map(copy_result, pending):
            if not result.get('copied') and not result.get('skipped'):
                failed += 1
            manifest.write(json.dumps(result) + '\n')
            manifest.flush()
    remaining = sum(needed(r) and not copied(r) for r in migration.inventory())
    print(json.dumps({'failed': failed, 'remaining': remaining, 'originals_deleted': 0, 'settings_changed': False}))
    if failed or remaining:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
