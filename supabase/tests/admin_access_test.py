#!/usr/bin/env python3
"""Check administrator gates with disposable identities in staging only.

Requires psycopg and private credential files. Requests use empty invalid
mutation payloads; the only allowed read is the empty staging notice list.
Never invokes AI, sends notifications or changes application business rows.
"""
import argparse
import hashlib
import json
import secrets
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import psycopg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['config', 'db-url-file', 'db-password-file', 'project-ref', 'output']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    if args.project_ref == 'clbhayqiwjawaawvrhcq':
        raise ValueError('Production testing is prohibited')
    if config['project_ref'] != args.project_ref or config['url'].rstrip('/') != f'https://{args.project_ref}.supabase.co':
        raise ValueError('Staging configuration mismatch')
    database_url = Path(args.db_url_file).read_text().strip()
    if args.project_ref not in database_url:
        raise ValueError('Database project mismatch')
    connection = psycopg.connect(database_url, password=Path(args.db_password_file).read_text().strip(), connect_timeout=20, autocommit=True)
    root = config['url'].rstrip('/')
    cases, users = [], {}
    requests = 0
    secret_added = False
    failure = None
    label = uuid.uuid4().hex
    routes = [
        ('admin-event-status', 'POST', 'invalid_action'),
        ('admin-correct-registration', 'POST', 'invalid_target'),
        ('admin-operating-notice', 'GET', None),
        ('admin-operating-notice', 'POST', 'invalid_notice'),
        ('register-event', 'POST', 'invalid_draft'),
        ('preview-event', 'POST', 'input_required'),
    ]

    def call(method, path, actor='anon', body=None):
        nonlocal requests
        token = config['service_role'] if actor == 'service' else users.get(actor, {}).get('token', config['anon'])
        headers = {'apikey': config['service_role'] if actor == 'service' else config['anon'], 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
        request = urllib.request.Request(root + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
        requests += 1
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                status, payload = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, payload = error.code, error.read()
        try:
            return status, json.loads(payload)
        except (ValueError, UnicodeDecodeError):
            return status, None

    def check(name, condition, status=None, code=None):
        cases.append({'case': name, 'passed': bool(condition), 'http_status': status, 'code': code})
        if not condition:
            raise AssertionError(f'{name}: verification failed (HTTP {status}, code {code})')

    def counts():
        relations = ['auth.users', 'auth.sessions', 'storage.objects', 'public.feedback_submissions', 'public.shop_events', 'public.shop_operating_notices']
        return {name: connection.execute('select count(*) from ' + name).fetchone()[0] for name in relations if connection.execute('select to_regclass(%s)', (name,)).fetchone()[0]}

    def secret_metadata():
        result = subprocess.run(['supabase', 'secrets', 'list', '--project-ref', args.project_ref, '--output', 'json'], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Unable to read staging secret metadata')
        rows = json.loads(result.stdout)
        return {row['name']: hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest() for row in rows}

    baseline = counts()
    before_secrets = secret_metadata()
    if 'ADMIN_ADDITIONAL_EMAILS' in before_secrets:
        raise ValueError('Refusing to overwrite an existing staging administrator secret')
    try:
        for actor in ['administrator', 'other']:
            email = f'security-admin-gate-{label}-{actor}@example.invalid'
            password = secrets.token_urlsafe(32)
            status, account = call('POST', '/auth/v1/admin/users', 'service', {'email': email, 'password': password, 'email_confirm': True, 'user_metadata': {'is_admin': True, 'role': 'admin'} if actor == 'other' else {}})
            check('create_' + actor, status == 200 and bool(account.get('id')) if isinstance(account, dict) else False, status)
            users[actor] = {'id': account['id'], 'email': email}
            status, session = call('POST', '/auth/v1/token?grant_type=password', body={'email': email, 'password': password})
            check('login_' + actor, status == 200 and bool(session.get('access_token')) if isinstance(session, dict) else False, status)
            users[actor]['token'] = session['access_token']
        with tempfile.NamedTemporaryFile(mode='w+', prefix='ramap-stage-admin-', suffix='.env') as env_file:
            env_file.write('ADMIN_ADDITIONAL_EMAILS=' + users['administrator']['email'] + '\n')
            env_file.flush()
            result = subprocess.run(['supabase', 'secrets', 'set', '--project-ref', args.project_ref, '--env-file', env_file.name], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Unable to configure disposable staging administrator')
        secret_added = True
        check('explicit_staging_admin_configuration', True)
        for actor in ['administrator', 'other', 'anon']:
            for function, method, expected_code in routes:
                status, response = call(method, '/functions/v1/' + function, actor, {} if method == 'POST' else None)
                code = response.get('code') if isinstance(response, dict) else None
                if actor == 'administrator':
                    accepted = status == 200 if method == 'GET' else status == 400 and code == expected_code
                else:
                    accepted = status == 403 and code == 'administrator_required'
                check(f'{actor}_{method}_{function}', accepted, status, code)
                if actor == 'administrator' and method == 'GET':
                    check('notice_list_contains_no_business_rows', isinstance(response, dict) and response.get('notices') == [])
        confirmed = connection.execute('select email_confirmed_at from auth.users where id=%s', (users['administrator']['id'],)).fetchone()[0]
        connection.execute('update auth.users set email_confirmed_at=null where id=%s', (users['administrator']['id'],))
        for function, method, _ in routes:
            status, response = call(method, '/functions/v1/' + function, 'administrator', {} if method == 'POST' else None)
            code = response.get('code') if isinstance(response, dict) else None
            check(f'unconfirmed_{method}_{function}', status == 403 and code == 'administrator_required', status, code)
        connection.execute('update auth.users set email_confirmed_at=%s where id=%s', (confirmed, users['administrator']['id']))
        check('business_rows_unchanged', all(counts()[key] == value for key, value in baseline.items() if key not in ['auth.users', 'auth.sessions']))
    except BaseException as error:
        failure = f'{type(error).__name__}: {error}'
    finally:
        for actor, account in users.items():
            status, _ = call('DELETE', '/auth/v1/admin/users/' + account['id'], 'service')
            if status >= 400:
                failure = failure or 'Disposable account cleanup failed'
        if secret_added:
            result = subprocess.run(['supabase', 'secrets', 'unset', 'ADMIN_ADDITIONAL_EMAILS', '--project-ref', args.project_ref], capture_output=True, text=True)
            if result.returncode:
                failure = failure or 'Disposable staging administrator secret cleanup failed'
        final = counts()
        after_secrets = secret_metadata()
        cleanup = final == baseline and after_secrets == before_secrets
        result = {'project': 'staging', 'cases': cases, 'http_requests': requests, 'passed_cases': sum(case['passed'] for case in cases), 'failure': failure, 'cleanup_restored_baseline': cleanup, 'baseline': baseline, 'final': final, 'existing_secrets_preserved': after_secrets == before_secrets, 'provider_calls': 0, 'notifications_sent': 0, 'production_requests': 0}
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        connection.close()
    print(json.dumps({key: result[key] for key in ['passed_cases', 'http_requests', 'failure', 'cleanup_restored_baseline', 'provider_calls', 'production_requests']}, ensure_ascii=False))
    if failure or not cleanup:
        raise AssertionError('See the sanitized result file for failed checks')


if __name__ == '__main__':
    main()
