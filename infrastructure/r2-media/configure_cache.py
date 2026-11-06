#!/usr/bin/env python3
"""공개 사진 캐시 삭제용 secret을 GCP와 Worker에 연결한다. 기존 값은 재사용한다."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from deploy_worker import WORKER, worker_configuration
from provision import validate

SECRET = 'ramap-worker-cache-purge'


def configure(config):
    settings = worker_configuration(config)
    project = config.get('gcp_project', 'ramap-54fc7')
    executable = WORKER / 'node_modules/.bin/wrangler'
    if not executable.exists():
        raise ValueError('Run npm --prefix services/public-media-worker ci first')

    def gcloud(*args, input=None, check=True):
        result = subprocess.run(['gcloud', *args, '--project', project, '--quiet'],
                                input=input, capture_output=True, text=True)
        if check and result.returncode:
            raise ValueError('Secret Manager operation failed: ' + ' '.join(args[:3]))
        return result

    # Reuse the current value so re-running setup cannot invalidate a running API.
    exists = gcloud('secrets', 'describe', SECRET, check=False).returncode == 0
    if exists:
        value = gcloud('secrets', 'versions', 'access', 'latest', '--secret=' + SECRET).stdout.strip()
        if len(value) < 32:
            raise ValueError('Existing cache secret is invalid; rotate it with a coordinated deployment')
    else:
        value = secrets.token_hex(32)
        gcloud('secrets', 'create', SECRET, '--replication-policy=automatic')
        gcloud('secrets', 'versions', 'add', SECRET, '--data-file=-', input=value)
    gcloud('secrets', 'add-iam-policy-binding', SECRET,
           '--member=serviceAccount:ramap-media@' + project + '.iam.gserviceaccount.com',
           '--role=roles/secretmanager.secretAccessor')
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', prefix='ramap-cache-worker-') as temporary:
        json.dump(settings, temporary)
        temporary.flush()
        result = subprocess.run([str(executable), 'secret', 'put', 'PUBLIC_CACHE_PURGE_SECRET', '--config', temporary.name],
                                cwd=WORKER, input=value, capture_output=True, text=True,
                                env={**os.environ, 'WRANGLER_SEND_METRICS': 'false'})
    if result.returncode:
        raise ValueError('Worker secret setup failed; existing GCP secret is preserved for retry')
    return {'configured': True, 'worker': settings['name'], 'gcp_secret': SECRET, 'reused': exists}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    config = validate(json.loads(args.config.read_text()))
    if config.get('public_delivery', 'worker') != 'worker':
        parser.error('Worker delivery mode is required')
    result = configure(config) if args.apply else {'configured': False, 'gcp_secret': SECRET, 'domain_purchase': False}
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from None
