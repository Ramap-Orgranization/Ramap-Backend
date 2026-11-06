#!/usr/bin/env python3
"""Verify report-photo RLS with disposable accounts in an explicit staging project.

Requires psycopg and local credential files. Never invokes Edge Functions,
providers, or a production project. All fixtures are removed in finally.
"""
import argparse
import base64
import hashlib
import json
import secrets
import urllib.error
import urllib.parse
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
    assert args.project_ref != 'clbhayqiwjawaawvrhcq', 'Production testing is prohibited'
    assert config['project_ref'] == args.project_ref
    assert config['url'].rstrip('/') == f'https://{args.project_ref}.supabase.co'
    database_url = Path(args.db_url_file).read_text().strip()
    assert args.project_ref in database_url, 'Database project mismatch'
    connection = psycopg.connect(
        database_url,
        password=Path(args.db_password_file).read_text().strip(),
        connect_timeout=20,
        autocommit=True,
    )
    bucket = 'news-report-evidence'
    root = config['url'].rstrip('/')
    checks, accounts, objects, report_paths = [], {}, [], []
    requests = 0
    label = uuid.uuid4().hex
    source = f'https://www.instagram.com/p/evidence_test_{label}/'
    image = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE1cAAAAASUVORK5CYII=')

    def call(method, path, actor='anon', body=None, raw=None):
        nonlocal requests
        token = config['service_role'] if actor == 'service' else accounts.get(actor, {}).get('token', config['anon'])
        data = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        headers = {'apikey': config['anon'], 'Authorization': 'Bearer ' + token}
        headers['Content-Type'] = 'image/png' if raw is not None else 'application/json'
        headers['Cache-Control'] = 'no-cache'
        if actor == 'service':
            headers['apikey'] = config['service_role']
        url = path if path.startswith('https://') else root + path
        assert urllib.parse.urlsplit(url).hostname == f'{args.project_ref}.supabase.co'
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        requests += 1
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                status, payload = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, payload = error.code, error.read()
        try:
            decoded = json.loads(payload)
        except (ValueError, UnicodeDecodeError):
            decoded = None
        return status, decoded, payload

    def check(name, condition, status=None, note=''):
        checks.append({'case': name, 'passed': bool(condition), 'http_status': status, 'note': note})
        if not condition:
            raise AssertionError(f'{name}: verification failed (HTTP {status})')

    def query(statement, values=()):
        return connection.execute(statement, values).fetchone()[0]

    def object_count(name):
        return query('select count(*) from storage.objects where bucket_id=%s and name=%s', (bucket, name))

    def upload(actor, suffix):
        name = f'security-evidence-{label}-{suffix}.png'
        objects.append((bucket, name))
        status, _, _ = call('POST', f'/storage/v1/object/{bucket}/{name}', actor, raw=image)
        check('upload_' + suffix, status == 200 and object_count(name) == 1, status)
        return name

    def download(name, actor):
        return call('GET', f'/storage/v1/object/authenticated/{bucket}/{name}', actor)

    def existing_evidence(owner, suffix):
        name = upload('service', suffix)
        connection.execute(
            'update storage.objects set owner_id=%s where bucket_id=%s and name=%s',
            (accounts[owner]['id'], bucket, name),
        )
        return name

    def denied_upload(actor, suffix):
        name = f'security-evidence-{label}-{suffix}.png'
        objects.append((bucket, name))
        status, _, _ = call('POST', f'/storage/v1/object/{bucket}/{name}', actor, raw=image)
        check('upload_denied_' + suffix, status >= 400 and object_count(name) == 0, status)

    baseline = {
        'users': query('select count(*) from auth.users'),
        'objects': query('select count(*) from storage.objects'),
        'feedback': query('select count(*) from public.feedback_submissions'),
        'administrators': query('select count(*) from community_private.news_report_evidence_administrators'),
    }
    check('news_report_submission_rpc_removed', query("select to_regprocedure('public.submit_news_report(text,text)') is null"))
    assert query("select count(*) from vault.decrypted_secrets where name='discord_feedback_webhook_url' and nullif(btrim(decrypted_secret),'') is not null") == 0, 'Staging notifications must be disabled'
    failure = None
    try:
        for actor in ['reporter', 'other', 'administrator']:
            email = f'evidence.{label}.{actor}@example.invalid'
            password = secrets.token_urlsafe(30)
            status, data, _ = call('POST', '/auth/v1/admin/users', 'service', {
                'email': email, 'password': password, 'email_confirm': True,
                'app_metadata': {'seed_tag': 'news-report-evidence-security-test'},
            })
            check('create_' + actor, status in [200, 201] and bool(data.get('id')), status)
            accounts[actor] = {'id': data['id']}
            status, session, _ = call('POST', '/auth/v1/token?grant_type=password', body={'email': email, 'password': password})
            check('login_' + actor, status == 200 and bool(session.get('access_token')), status)
            accounts[actor].update(token=session['access_token'], refresh=session['refresh_token'])
        connection.execute('insert into community_private.news_report_evidence_administrators(user_id) values (%s)', (accounts['administrator']['id'],))
        check('administrator_membership', query('select count(*) from community_private.news_report_evidence_administrators where user_id=%s', (accounts['administrator']['id'],)) == 1)

        # Seed existing user-owned photos through the trusted fixture path.
        submitted = existing_evidence('reporter', 'submitted')
        unused = existing_evidence('reporter', 'unused')
        other = existing_evidence('other', 'other')
        legacy = upload('service', 'ownerless')
        administrative = upload('administrator', 'administrator')
        check('administrator_upload_owner', query('select owner_id from storage.objects where bucket_id=%s and name=%s', (bucket, administrative)) == accounts['administrator']['id'])
        check('owner_identity', query('select owner_id from storage.objects where bucket_id=%s and name=%s', (bucket, submitted)) == accounts['reporter']['id'])
        check('legacy_owner_absent', query('select owner_id from storage.objects where bucket_id=%s and name=%s', (bucket, legacy)) is None)
        connection.execute("insert into public.feedback_submissions(feedback_type,message,attachment_path) values ('news_report',%s,%s)", (source, submitted))
        report_paths.append(submitted)

        for actor in ['anon', 'reporter', 'other']:
            denied_upload(actor, actor)
        for actor in ['anon', 'reporter', 'other', 'administrator']:
            status, _, payload = call('GET', f'/storage/v1/object/public/{bucket}/{submitted}', actor)
            check('public_url_denied_' + actor, status >= 400 and payload != image, status)
        for actor, allowed in [('reporter', True), ('administrator', True), ('service', True), ('other', False), ('anon', False)]:
            status, _, payload = download(submitted, actor)
            check('private_read_' + actor, status == 200 and payload == image if allowed else status >= 400 and payload != image, status)
        for actor, allowed in [('reporter', False), ('other', False), ('administrator', True)]:
            status, _, payload = download(legacy, actor)
            check('ownerless_read_' + actor, status == 200 and payload == image if allowed else status >= 400 and payload != image, status)

        for actor in ['anon', 'reporter', 'other', 'administrator']:
            status, rows, _ = call('POST', f'/storage/v1/object/list/{bucket}', actor, {'prefix': '', 'limit': 100})
            names = {row['name'] for row in rows if row['name'].startswith(f'security-evidence-{label}')} if isinstance(rows, list) else set()
            if actor == 'reporter':
                permitted = status == 200 and submitted in names and unused in names and other not in names and legacy not in names
            elif actor == 'administrator':
                permitted = status == 200 and {submitted, unused, other, legacy}.issubset(names)
            elif actor == 'other':
                permitted = status == 200 and other in names and submitted not in names and legacy not in names
            else:
                permitted = not names
            check('list_boundary_' + actor, permitted, status)
        for actor in ['anon', 'other', 'reporter', 'administrator', 'service']:
            status, result, _ = call('POST', f'/storage/v1/object/sign/{bucket}/{submitted}', actor, {'expiresIn': 300 if actor == 'service' else 60})
            signed = result.get('signedURL') if isinstance(result, dict) else None
            allowed = actor in ['reporter', 'administrator', 'service']
            check('sign_boundary_' + actor, status == 200 and bool(signed) if allowed else status >= 400 and not signed, status)
            if allowed:
                path = signed if signed.startswith('https://') else '/storage/v1' + signed
                status, _, payload = call('GET', path)
                check('short_signed_capability_' + actor, status == 200 and payload == image, status, 'Only authorized actors can mint the temporary bearer URL; no URL/token is recorded.')

        status, _, _ = call('PUT', '/auth/v1/user', 'other', {'data': {'is_admin': True, 'role': 'admin'}})
        check('self_editable_metadata_fixture', status == 200, status)
        status, session, _ = call('POST', '/auth/v1/token?grant_type=refresh_token', body={'refresh_token': accounts['other']['refresh']})
        check('refresh_spoofed_metadata_fixture', status == 200, status)
        accounts['other']['token'] = session['access_token']
        status, _, payload = download(submitted, 'other')
        check('user_metadata_cannot_grant_admin', status >= 400 and payload != image, status)
        denied_upload('other', 'spoofed-administrator')
        try:
            with connection.transaction():
                connection.execute('set local role authenticated')
                connection.execute("select set_config('request.jwt.claims',%s,true)", (json.dumps({'sub': accounts['other']['id'], 'role': 'authenticated'}),))
                connection.execute('insert into community_private.news_report_evidence_administrators(user_id) values (%s)', (accounts['other']['id'],))
            writable = True
        except psycopg.errors.InsufficientPrivilege:
            writable = False
        check('membership_cannot_be_self_assigned', not writable)

        status, _, _ = call('DELETE', f'/storage/v1/object/{bucket}', 'other', {'prefixes': [submitted]})
        check('other_cannot_delete', object_count(submitted) == 1, status)
        status, _, _ = call('DELETE', f'/storage/v1/object/{bucket}', 'anon', {'prefixes': [submitted]})
        check('anonymous_cannot_delete', object_count(submitted) == 1, status)
        status, _, _ = call('DELETE', f'/storage/v1/object/{bucket}', 'reporter', {'prefixes': [submitted]})
        check('submitted_evidence_preserved', object_count(submitted) == 1, status)
        status, _, _ = call('DELETE', f'/storage/v1/object/{bucket}', 'reporter', {'prefixes': [unused]})
        check('failed_duplicate_cleanup_removes_object', status == 200 and object_count(unused) == 0, status)
        status, _, _ = call('DELETE', f'/storage/v1/object/{bucket}', 'administrator', {'prefixes': [legacy]})
        check('administrator_cleanup', status == 200 and object_count(legacy) == 0, status)
        status, _, _ = call('PUT', f'/storage/v1/object/{bucket}/{submitted}', 'reporter', raw=image + b'changed')
        status_read, _, payload = download(submitted, 'reporter')
        check('evidence_overwrite_denied', status >= 400 and status_read == 200 and payload == image, status)

        check('image_bytes_verified', hashlib.sha256(payload).digest() == hashlib.sha256(image).digest())
    except BaseException as error:
        failure = f'{type(error).__name__}: {error}'
    finally:
        connection.execute('delete from public.feedback_submissions where message like %s or attachment_path = any(%s)', (source + '%', report_paths))
        for object_bucket in set(item[0] for item in objects):
            names = [name for current, name in objects if current == object_bucket]
            call('DELETE', f'/storage/v1/object/{object_bucket}', 'service', {'prefixes': names})
        for account in accounts.values():
            connection.execute('delete from community_private.news_report_evidence_administrators where user_id=%s', (account['id'],))
            call('DELETE', '/auth/v1/admin/users/' + account['id'], 'service')
        final = {
            'users': query('select count(*) from auth.users'),
            'objects': query('select count(*) from storage.objects'),
            'feedback': query('select count(*) from public.feedback_submissions'),
            'administrators': query('select count(*) from community_private.news_report_evidence_administrators'),
        }
        cleanup = final == baseline
        result = {
            'project': 'staging', 'cases': checks, 'http_requests': requests,
            'passed_cases': sum(case['passed'] for case in checks), 'failure': failure,
            'cleanup_restored_baseline': cleanup, 'baseline': baseline, 'final': final,
            'provider_calls': 0, 'production_requests': 0,
        }
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        connection.close()
    print(json.dumps({key: result[key] for key in ['passed_cases', 'http_requests', 'failure', 'cleanup_restored_baseline', 'provider_calls', 'production_requests']}, ensure_ascii=False))
    assert failure is None and cleanup, 'See the sanitized result file for failed checks'


if __name__ == '__main__':
    main()
