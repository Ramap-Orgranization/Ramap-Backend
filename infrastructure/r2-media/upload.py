#!/usr/bin/env python3
"""관리자 공개 사진을 준비·직접 전송·검증하고 논리 경로만 반환한다."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.parse

from media_client import MediaService, PUBLIC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--bucket', choices=sorted(PUBLIC), required=True)
    parser.add_argument('--path', required=True)
    parser.add_argument('--file', type=Path, required=True)
    parser.add_argument('--content-type', choices=['image/jpeg', 'image/png', 'image/webp'], required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    migration = MediaService(config)
    content = args.file.read_bytes()
    checksum = hashlib.sha256(content).hexdigest()
    def call(action, body):
        result = migration.request('POST', config['media_api_url'] + '/internal/' + ('v2/' if config.get('r2_account_id') else '') + action, json.dumps(body).encode(),
            {'Authorization': 'Bearer ' + migration.key, 'Content-Type': 'application/json'})
        return json.loads(result)
    prepared = call('prepare', {'bucket': args.bucket, 'path': args.path, 'content_type': args.content_type, 'byte_size': len(content)})
    if prepared['provider'] == 'supabase':
        target = migration.root + '/storage/v1/object/' + urllib.parse.quote(args.bucket + '/' + args.path, safe='/')
        migration.request('POST', target, content, {'Authorization': 'Bearer ' + migration.key, 'apikey': migration.key, 'Content-Type': args.content_type})
        public_url = migration.root + '/storage/v1/object/public/' + urllib.parse.quote(args.bucket + '/' + args.path, safe='/')
    else:
        if not prepared.get('ready'):
            target = urllib.parse.urlsplit(prepared['url'])
            query = urllib.parse.parse_qs(target.query)
            r2 = (prepared['provider'] == 'r2' and config.get('r2_account_id')
                  and target.hostname == config['r2_account_id'] + '.r2.cloudflarestorage.com'
                  and target.path == '/' + config['r2_private_bucket'] + '/pending/' + prepared['id']
                  and query.get('X-Amz-Algorithm') == ['AWS4-HMAC-SHA256'] and query.get('X-Amz-Signature'))
            if target.scheme != 'https' or target.username or target.password or target.fragment or target.port not in (None, 443) or not r2:
                raise SystemExit('Invalid signed upload target')
            headers = {'Content-Type': args.content_type, 'If-None-Match': '*'}
            migration.request('PUT', prepared['url'], content, headers)
            call('finalize', {'id': prepared['id']})
        public_url = config['r2_public_base_url'].rstrip('/') + '/' + urllib.parse.quote(args.bucket + '/' + args.path, safe='/')
    downloaded = migration.request('GET', public_url)
    if hashlib.sha256(downloaded).hexdigest() != checksum:
        raise SystemExit('Public image checksum mismatch')
    print(json.dumps({'path': args.path, 'provider': prepared['provider'], 'public_url': public_url,
                      'sha256': checksum, 'byte_size': len(content), 'verified': True}))


if __name__ == '__main__':
    main()
