#!/usr/bin/env python3
"""R2 사진 제어 API와 30분 정리 작업을 서울 Cloud Run에 배포한다. 기본은 읽기 전용 계획 출력이다."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

PROJECT = 'ramap-54fc7'
REGION = 'asia-northeast3'
ACCOUNT = 'ramap-media'
SERVICE = 'ramap-media'
SUPABASE_REF = 'clbhayqiwjawaawvrhcq'
ROOT = Path(__file__).resolve().parents[2]


def gcloud(*arguments, capture=False, check=True):
    command = ['gcloud', *arguments, '--project', PROJECT, '--quiet']
    result = subprocess.run(command, capture_output=capture, text=True)
    if check and result.returncode:
        raise SystemExit('gcloud command failed: ' + ' '.join(arguments[:3]))
    return result


def json_command(*arguments):
    result = gcloud(*arguments, '--format=json', capture=True, check=False)
    return json.loads(result.stdout) if result.returncode == 0 else None


def secrets():
    result = subprocess.run(['supabase', 'projects', 'api-keys', '--project-ref', SUPABASE_REF, '--output', 'json'],
                            check=True, capture_output=True, text=True)
    rows = json.loads(result.stdout)
    if not isinstance(rows, list):
        rows = rows.get('api_keys', rows.get('keys', []))
    keys = {row.get('name'): row.get('api_key') for row in rows}
    if not keys.get('anon') or not keys.get('service_role'):
        raise SystemExit('Configured Supabase server keys are unavailable')
    return {'ramap-media-anon': keys['anon'], 'ramap-media-service': keys['service_role']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--redeploy-only', action='store_true', help='기존 IAM·secret을 유지하고 코드만 배포')
    parser.add_argument('--r2-config', type=Path, help='로컬 전용 R2 연결 설정. R2 읽기·쓰기는 활성화하지 않음')
    parser.add_argument('--output', type=Path, help='비밀값이 없는 배포 연결 설정 출력')
    args = parser.parse_args()
    r2_config = None
    if args.r2_config:
        import sys
        sys.path.insert(0, str(ROOT / 'infrastructure/r2-media'))
        from provision import validate
        r2_config = validate(json.loads(args.r2_config.read_text()))
    if not args.apply:
        print(json.dumps({'project': PROJECT, 'region': REGION, 'photo_storage': 'r2',
                          'service': SERVICE, 'legacy_mirror': True, 'minimum_instances': 0, 'maximum_instances': 2, 'r2': r2_config}, indent=2))
        return
    service_account = f'{ACCOUNT}@{PROJECT}.iam.gserviceaccount.com'
    if not args.redeploy_only:
        gcloud('services', 'enable', 'run.googleapis.com', 'cloudbuild.googleapis.com',
               'artifactregistry.googleapis.com', 'secretmanager.googleapis.com', 'cloudscheduler.googleapis.com')
        if json_command('iam', 'service-accounts', 'describe', service_account) is None:
            gcloud('iam', 'service-accounts', 'create', ACCOUNT, '--display-name=Ramap photo storage')
        for name, value in secrets().items():
            if json_command('secrets', 'describe', name) is None:
                gcloud('secrets', 'create', name, '--replication-policy=automatic')
            with tempfile.NamedTemporaryFile(mode='w', prefix='ramap-media-secret-') as temporary:
                temporary.write(value)
                temporary.flush()
                gcloud('secrets', 'versions', 'add', name, '--data-file=' + temporary.name)
            gcloud('secrets', 'add-iam-policy-binding', name, '--member=serviceAccount:' + service_account,
                   '--role=roles/secretmanager.secretAccessor')
    variables = {'SUPABASE_URL': f'https://{SUPABASE_REF}.supabase.co'}
    bindings_map = {'SUPABASE_ANON_KEY': 'ramap-media-anon:latest', 'SUPABASE_SERVICE_ROLE_KEY': 'ramap-media-service:latest'}
    # Keep R2 settings on subsequent API redeploys.
    previous = json_command('run', 'services', 'describe', SERVICE, '--region', REGION) or {}
    containers = previous.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])
    for entry in (containers[0].get('env', []) if containers else []):
        name = entry['name']
        if name.startswith('R2_') or name.startswith('CLOUDFLARE_') or name == 'LEGACY_GCS_CLEANUP_BUCKETS':
            if 'value' in entry:
                variables[name] = entry['value']
            reference = entry.get('valueFrom', {}).get('secretKeyRef')
            if reference:
                bindings_map[name] = reference['name'] + ':' + reference['key']
    if r2_config:
        if 'legacy_gcs_cleanup_buckets' in r2_config:
            variables['LEGACY_GCS_CLEANUP_BUCKETS'] = ';'.join(r2_config['legacy_gcs_cleanup_buckets'])
        variables.update({'R2_ACCOUNT_ID': r2_config['r2_account_id'], 'R2_PUBLIC_BUCKET': r2_config['r2_public_bucket'],
                          'R2_PRIVATE_BUCKET': r2_config['r2_private_bucket'], 'R2_PUBLIC_BASE_URL': r2_config.get('r2_public_base_url', ''),
                          'R2_PUBLIC_DELIVERY': r2_config.get('public_delivery', 'worker'),
                          'CLOUDFLARE_ZONE_ID': r2_config.get('cloudflare_zone_id', '')})
        bindings_map.update({'R2_ACCESS_KEY_ID': 'ramap-r2-access:latest', 'R2_SECRET_ACCESS_KEY': 'ramap-r2-secret:latest'})
        if variables['R2_PUBLIC_DELIVERY'] == 'custom_domain':
            bindings_map['CLOUDFLARE_CACHE_PURGE_TOKEN'] = 'ramap-r2-cache-purge:latest'
        else:
            bindings_map.pop('CLOUDFLARE_CACHE_PURGE_TOKEN', None)
    if variables.get('R2_PUBLIC_DELIVERY') == 'worker':
        bindings_map['R2_WORKER_PURGE_SECRET'] = 'ramap-worker-cache-purge:latest'
    bindings = ','.join(name + '=' + value for name, value in bindings_map.items())
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', prefix='ramap-media-env-') as temporary:
        json.dump(variables, temporary)
        temporary.flush()
        gcloud('run', 'deploy', SERVICE, '--source', str(ROOT / 'services/media-api'), '--region', REGION,
               '--service-account', service_account, '--allow-unauthenticated', '--min-instances=0', '--max-instances=2',
               '--concurrency=4', '--memory=512Mi', '--cpu=1', '--timeout=60', '--env-vars-file=' + temporary.name,
               '--set-secrets=' + bindings)
    description = json_command('run', 'services', 'describe', SERVICE, '--region', REGION)
    url = description['status']['url']
    image = description['spec']['template']['spec']['containers'][0]['image']
    environment = ','.join(name + '=' + value for name, value in variables.items())
    job = SERVICE + '-cleanup'
    operation = 'update' if json_command('run', 'jobs', 'describe', job, '--region', REGION) else 'create'
    gcloud('run', 'jobs', operation, job, '--region', REGION, '--image', image, '--service-account', service_account,
           '--command=node', '--args=worker.mjs', '--tasks=1', '--max-retries=2', '--task-timeout=300',
           '--set-env-vars=' + environment, '--set-secrets=' + bindings, '--memory=512Mi')
    scheduler = SERVICE + '-cleanup'
    schedule_operation = 'update' if json_command('scheduler', 'jobs', 'describe', scheduler, '--location', REGION) else 'create'
    gcloud('run', 'jobs', 'add-iam-policy-binding', job, '--region', REGION, '--member=serviceAccount:' + service_account,
           '--role=roles/run.invoker')
    gcloud('scheduler', 'jobs', schedule_operation, 'http', scheduler, '--location', REGION, '--schedule=*/30 * * * *',
           '--uri=' + f'https://run.googleapis.com/v2/projects/{PROJECT}/locations/{REGION}/jobs/{job}:run',
           '--http-method=POST', '--oauth-service-account-email=' + service_account, '--message-body={}')
    config = {'region': REGION, 'media_api_url': url, 'supabase_ref': SUPABASE_REF}
    if variables.get('R2_ACCOUNT_ID'):
        config.update({'r2_account_id': variables['R2_ACCOUNT_ID'], 'r2_private_bucket': variables['R2_PRIVATE_BUCKET'],
                       'r2_public_base_url': variables.get('R2_PUBLIC_BASE_URL', ''), 'public_delivery': variables.get('R2_PUBLIC_DELIVERY', 'custom_domain')})
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(config, indent=2) + '\n')
    print(json.dumps(config, indent=2))


if __name__ == '__main__':
    main()
