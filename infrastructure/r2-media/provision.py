#!/usr/bin/env python3
"""R2 리소스 준비. 기본은 계획 출력이며 도메인 구매와 데이터 삭제를 수행하지 않는다."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request


def validate(config):
    if not re.fullmatch(r'[a-f0-9]{32}', config.get('r2_account_id', '')):
        raise ValueError('Cloudflare account ID is required')
    buckets = [config.get('r2_public_bucket', ''), config.get('r2_private_bucket', '')]
    if len(set(buckets)) != 2 or any(not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,61}[a-z0-9]', b) for b in buckets):
        raise ValueError('Two distinct R2 bucket names are required')
    retired_buckets = config.get('legacy_gcs_cleanup_buckets', [])
    if not isinstance(retired_buckets, list) or any(not isinstance(bucket, str) or not re.fullmatch(r'[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]', bucket) for bucket in retired_buckets):
        raise ValueError('Invalid retired media buckets')
    delivery = config.get('public_delivery', 'worker')
    if 'public_cache_enabled' in config and not isinstance(config['public_cache_enabled'], bool):
        raise ValueError('public_cache_enabled must be a boolean')
    if delivery not in ('worker', 'custom_domain'):
        raise ValueError('Invalid public delivery mode')
    worker = config.get('public_worker_name', 'ramap-images')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,61}', worker):
        raise ValueError('Invalid Worker name')
    domain = config.get('r2_public_base_url')
    if domain:
        url = urllib.parse.urlsplit(domain)
        if (url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment
            or url.path not in ('', '/') or url.port not in (None, 443)):
            raise ValueError('Invalid public image URL')
        if delivery == 'worker':
            if not re.fullmatch(re.escape(worker) + r'\.[a-z0-9-]+\.workers\.dev', url.hostname):
                raise ValueError('Use the deployed Worker URL; no domain purchase is needed')
        elif (url.hostname.endswith(('.r2.dev', '.r2.cloudflarestorage.com', '.workers.dev'))
              or not re.fullmatch(r'[a-f0-9]{32}', config.get('cloudflare_zone_id', ''))):
            raise ValueError('Owned HTTPS domain and Cloudflare zone ID are required for custom_domain mode')
    return config


def cloudflare(config, method, path, body=None):
    token = os.environ.get('CLOUDFLARE_API_TOKEN')
    if not token:
        raise ValueError('Set CLOUDFLARE_API_TOKEN in the local environment')
    url = 'https://api.cloudflare.com/client/v4/accounts/' + config['r2_account_id'] + '/r2/buckets' + path
    request = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                    headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise ValueError('Cloudflare request failed (HTTP ' + str(error.code) + ')') from None
    if not payload.get('success'):
        raise ValueError('Cloudflare rejected the configuration')
    return payload.get('result')


def provision(config):
    buckets = cloudflare(config, 'GET', '')['buckets']
    existing = {b['name']: b for b in buckets}
    for bucket in (config['r2_public_bucket'], config['r2_private_bucket']):
        if bucket not in existing:
            cloudflare(config, 'POST', '', {'name': bucket, 'locationHint': 'apac', 'storageClass': 'Standard'})
        elif existing[bucket].get('storageClass', 'Standard') != 'Standard':
            raise ValueError('Existing bucket is not Standard storage')
        path = '/' + urllib.parse.quote(bucket, safe='') + '/domains/'
        cloudflare(config, 'PUT', path + 'managed', {'enabled': False})
        domains = cloudflare(config, 'GET', path + 'custom').get('domains', [])
        if bucket == config['r2_private_bucket'] and any(d.get('enabled') for d in domains):
            raise ValueError('Private bucket has a public domain; stop and review it')
        if config.get('public_delivery', 'worker') == 'worker' and any(d.get('enabled') for d in domains):
            raise ValueError('Existing public domain requires a separate cache-retirement plan')
        if bucket == config['r2_public_bucket'] and config.get('public_delivery', 'worker') == 'custom_domain' and config.get('r2_public_base_url'):
            domain = urllib.parse.urlsplit(config['r2_public_base_url']).hostname
            current = next((d for d in domains if d['domain'] == domain), None)
            settings = {'domain': domain, 'enabled': True, 'zoneId': config['cloudflare_zone_id']}
            if current is None:
                cloudflare(config, 'POST', path + 'custom', settings)
            elif not current.get('enabled'):
                cloudflare(config, 'PUT', path + 'custom/' + domain, {'enabled': True})


def store_secrets(config):
    project = config.get('gcp_project', 'ramap-54fc7')
    account = f'ramap-media@{project}.iam.gserviceaccount.com'
    names = {'R2_ACCESS_KEY_ID': 'ramap-r2-access', 'R2_SECRET_ACCESS_KEY': 'ramap-r2-secret'}
    if config.get('public_delivery', 'worker') == 'custom_domain':
        names['CLOUDFLARE_CACHE_PURGE_TOKEN'] = 'ramap-r2-cache-purge'
    if any(not os.environ.get(name) for name in names):
        raise ValueError('Set the required storage secrets in the local environment first')
    def gcloud(*args, input=None, check=True):
        result = subprocess.run(['gcloud', *args, '--project', project, '--quiet'], input=input, capture_output=True, text=True)
        if check and result.returncode:
            raise ValueError('Secret Manager operation failed: ' + ' '.join(args[:3]))
        return result
    for environment, name in names.items():
        if gcloud('secrets', 'describe', name, check=False).returncode:
            gcloud('secrets', 'create', name, '--replication-policy=automatic')
        gcloud('secrets', 'versions', 'add', name, '--data-file=-', input=os.environ[environment])
        gcloud('secrets', 'add-iam-policy-binding', name, '--member=serviceAccount:' + account, '--role=roles/secretmanager.secretAccessor')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--store-secrets', action='store_true')
    args = parser.parse_args()
    config = validate(json.loads(args.config.read_text()))
    if args.apply:
        provision(config)
    if args.store_secrets:
        store_secrets(config)
    print(json.dumps({'applied': args.apply, 'secrets_stored': args.store_secrets,
                      'storage_class': 'Standard', 'location_hint': 'apac', 'guaranteed_region': False,
                      'public_delivery': config.get('public_delivery', 'worker'), 'public_url': config.get('r2_public_base_url'),
                      'domain_purchase': False, 'r2_dev': False}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from None
