#!/usr/bin/env python3
"""격리 staging에서 매장 정보 제보 중복·한도·권한·롤백을 검증하고 fixture를 정리한다."""
import argparse
import concurrent.futures
import json
import secrets
import threading
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
    database_url = Path(args.db_url_file).read_text().strip()
    assert args.project_ref == 'gedptwzjortijxpjvmbc' and config['project_ref'] == args.project_ref
    assert args.project_ref in database_url and config['url'].rstrip('/') == f'https://{args.project_ref}.supabase.co'
    connection = psycopg.connect(database_url, password=Path(args.db_password_file).read_text().strip(), autocommit=True, connect_timeout=20)
    cases, accounts = [], {}
    requests, request_lock = 0, threading.Lock()
    failure = None
    label = uuid.uuid4().hex
    shop_id = str(uuid.uuid4())
    source_prefix = f'https://report-test.invalid/{label}/'
    tables = {'shop_information': 'shop_information_reports'}
    helper_created = False

    def query(sql, values=()):
        return connection.execute(sql, values).fetchone()[0]

    def check(name, condition, **details):
        cases.append({'case': name, 'passed': bool(condition), **details})
        if not condition:
            raise AssertionError(name)

    def call(method, path, body=None, actor='anon', headers=None):
        nonlocal requests
        token = config['service_role'] if actor == 'service' else accounts.get(actor, {}).get('token', config['anon'])
        request_headers = {'apikey': config['service_role'] if actor == 'service' else config['anon'], 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', **(headers or {})}
        data = json.dumps(body).encode() if body is not None else None
        with request_lock:
            requests += 1
        request = urllib.request.Request(config['url'].rstrip('/') + path, data=data, headers=request_headers, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            payload = response.read()
            status, response_headers = response.status, response.headers
        try:
            decoded = json.loads(payload) if payload else None
        except ValueError:
            decoded = None
        return status, decoded, response_headers

    def snapshot():
        return query("""select jsonb_build_object(
            'settings',(select jsonb_agg(jsonb_build_object('kind',kind,'global_minute_limit',global_minute_limit,'global_daily_limit',global_daily_limit,'actor_minute_limit',actor_minute_limit,'actor_daily_limit',actor_daily_limit,'enabled',enabled,'secret_digest',encode(extensions.digest(digest_secret,'sha256'),'hex')) order by kind) from report_submission_private.submission_limits),
            'counters',(select count(*) from report_submission_private.submission_counters),
            'recent',(select count(*) from report_submission_private.recent_submissions),
            'users',(select count(*) from auth.users),'profiles',(select count(*) from public.public_profiles),'objects',(select count(*) from storage.objects),'shops',(select count(*) from public.ramen_shops),
            'feedback',(select count(*) from public.feedback_submissions),'shop_information',(select count(*) from public.shop_information_reports),'unregistered_place',(select count(*) from public.unregistered_place_reports))""")

    baseline = snapshot()
    assert baseline['counters'] == 0 and baseline['recent'] == 0, 'Refusing to overwrite an active staging quota'
    assert query("select count(*) from vault.secrets where name in ('discord_feedback_webhook_url','discord_new_shop_webhook_url','discord_shop_information_webhook_url')") == 0, 'Staging notifications must be unconfigured'
    assert query("select count(*) from pg_namespace where nspname='report_submission_test'") == 0

    def clear():
        for kind, table in tables.items():
            connection.execute('delete from public.' + table + ' where id in (select report_id from report_submission_test.notifications where kind=%s)', (kind,))
        connection.execute('delete from report_submission_test.notifications')
        connection.execute('delete from report_submission_private.submission_counters')
        connection.execute('delete from report_submission_private.recent_submissions')
        connection.execute('update report_submission_private.submission_limits set global_minute_limit=1000,global_daily_limit=1000,actor_minute_limit=1000,actor_daily_limit=1000,enabled=true where kind = any(%s)', (list(tables),))

    def payload(kind, suffix):
        if kind == 'shop_information':
            return {'id': str(uuid.uuid4()), 'shop_id': shop_id, 'shop_name': 'Synthetic report shop', 'wrong_fields': ['address', 'phone'], 'description': label + '-' + suffix}
        return {'id': str(uuid.uuid4()), 'place_url': source_prefix + suffix}

    def submit(kind, suffix, actor='anon', headers=None, value=None):
        return call('POST', '/rest/v1/' + tables[kind], value if value is not None else payload(kind, suffix), actor, {'Prefer': 'return=minimal', **(headers or {})})

    def total(kind):
        return query('select count(*) from report_submission_test.notifications where kind=%s', (kind,))

    def daily(kind):
        return query("select coalesce(sum(consumed),0) from report_submission_private.submission_counters where kind=%s and scope='global_day'", (kind,))

    def limit_reply(reply):
        status, body, headers = reply
        return status == 429 and body.get('code') == 'REPORT_RATE_LIMITED' and retry_seconds(headers) > 0

    def retry_seconds(headers):
        # The hosted gateway can add a second Retry-After to a 503 reply (0, 30).
        values = [value.strip() for value in headers.get('Retry-After', '').split(',')]
        return max([int(value) for value in values if value.isdigit()], default=0)

    try:
        connection.execute('create schema report_submission_test')
        helper_created = True
        connection.execute('create table report_submission_test.notifications(kind text,report_id uuid primary key)')
        connection.execute("""create function report_submission_test.capture() returns trigger language plpgsql security definer set search_path='' as $$
        begin
            insert into report_submission_test.notifications(kind,report_id) values
            (case tg_table_name when 'shop_information_reports' then 'shop_information' else 'unregistered_place' end,new.id);
            return new;
        end;$$""")
        connection.execute('revoke all on schema report_submission_test from public,anon,authenticated')
        connection.execute('revoke all on function report_submission_test.capture() from public,anon,authenticated')
        for table in tables.values():
            connection.execute('create trigger zz_report_test_capture after insert on public.' + table + ' for each row execute function report_submission_test.capture()')
        connection.execute('insert into public.ramen_shops(id,name,address,lat,lng) values (%s,%s,%s,37,127)', (shop_id, 'Synthetic report shop', 'Synthetic only'))

        for role in ['anon', 'authenticated']:
            for operation in ['select * from report_submission_private.submission_limits', 'select * from report_submission_private.submission_counters', 'delete from report_submission_private.recent_submissions', "select report_submission_private.admit_submission('shop_information','forged')"]:
                denied = False
                try:
                    with connection.transaction(force_rollback=True):
                        connection.execute('set local role ' + role)
                        connection.execute(operation)
                except psycopg.errors.InsufficientPrivilege:
                    denied = True
                check(role + '_private_' + operation.split()[0] + '_' + str(len(cases)), denied)
        denied = False
        try:
            with connection.transaction(force_rollback=True):
                connection.execute('set local role service_role')
                connection.execute('select digest_secret from report_submission_private.submission_limits')
        except psycopg.errors.InsufficientPrivilege:
            denied = True
        check('service_role_cannot_read_digest_secret', denied)

        for actor in ['A', 'B']:
            password = secrets.token_urlsafe(30)
            email = f'report.{label}.{actor}@example.invalid'
            status, user, _ = call('POST', '/auth/v1/admin/users', {'email': email, 'password': password, 'email_confirm': True, 'user_metadata': {'role': 'service_role'}}, 'service')
            check('create_account_' + actor, status in [200, 201] and bool(user.get('id')), http_status=status)
            accounts[actor] = {'id': user['id']}
            status, session, _ = call('POST', '/auth/v1/token?grant_type=password', {'email': email, 'password': password})
            check('sign_in_once_' + actor, status == 200 and bool(session.get('access_token')), http_status=status)
            accounts[actor]['token'] = session['access_token']

        for kind in tables:
            clear()
            first = submit(kind, 'same')
            second = submit(kind, 'same', 'A')
            check(kind + '_duplicate_success_contract', first[0] in [200, 201] and second[0] in [200, 201])
            check(kind + '_duplicate_one_row_one_notification_one_unit', total(kind) == 1 and daily(kind) == 1)

            clear()
            connection.execute('update report_submission_private.submission_limits set actor_minute_limit=2 where kind=%s', (kind,))
            replies = [submit(kind, 'actor-minute-' + str(i)) for i in range(3)]
            check(kind + '_anonymous_actor_minute_limit', replies[0][0] in [200, 201] and replies[1][0] in [200, 201] and limit_reply(replies[2]))
            check(kind + '_denial_creates_no_row_notification_or_unit', total(kind) == 2 and daily(kind) == 2 and query('select count(*) from report_submission_private.recent_submissions') == 2)
            duplicate = submit(kind, 'actor-minute-0')
            check(kind + '_duplicate_allowed_after_budget_exhaustion', duplicate[0] in [200, 201] and daily(kind) == 2)

            clear()
            connection.execute('update report_submission_private.submission_limits set actor_daily_limit=2 where kind=%s', (kind,))
            replies = [submit(kind, 'account-day-' + str(i), 'A', {'x-forwarded-for': f'203.0.113.{i}', 'x-user-id': str(uuid.uuid4())}) for i in range(3)]
            check(kind + '_authenticated_actor_day_not_bypassed_by_metadata_or_headers', replies[0][0] in [200, 201] and replies[1][0] in [200, 201] and limit_reply(replies[2]))
            check(kind + '_second_account_is_independent', submit(kind, 'second-account', 'B')[0] in [200, 201] and total(kind) == 3)

            clear()
            connection.execute('update report_submission_private.submission_limits set global_daily_limit=2 where kind=%s', (kind,))
            replies = [submit(kind, 'global-day-' + str(i), ['anon', 'A', 'B'][i]) for i in range(3)]
            check(kind + '_global_day_applies_to_all_actors', replies[0][0] in [200, 201] and replies[1][0] in [200, 201] and limit_reply(replies[2]) and total(kind) == 2)
            check(kind + '_day_window_is_KST_midnight', query("select bool_and(extract(hour from window_start at time zone 'Asia/Seoul')=0 and extract(minute from window_start at time zone 'Asia/Seoul')=0) from report_submission_private.submission_counters where scope='global_day'"))

            clear()
            connection.execute('update report_submission_private.submission_limits set global_minute_limit=2 where kind=%s', (kind,))
            replies = [submit(kind, 'global-minute-' + str(i), ['anon', 'A', 'B'][i]) for i in range(3)]
            check(kind + '_global_minute_applies_to_all_actors', replies[0][0] in [200, 201] and replies[1][0] in [200, 201] and limit_reply(replies[2]) and total(kind) == 2)

            clear()
            connection.execute('update report_submission_private.submission_limits set enabled=false where kind=%s', (kind,))
            status, body, headers = submit(kind, 'disabled')
            check(kind + '_disabled_fails_closed', status == 503 and body.get('code') == 'REPORT_SUBMISSION_UNAVAILABLE' and retry_seconds(headers) == 30 and total(kind) == 0 and daily(kind) == 0, http_status=status, code=body.get('code'), retry_after=headers.get('Retry-After'))

            clear()
            def same_submission(index):
                return submit(kind, 'parallel-same', ['anon', 'A', 'B'][index % 3])
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
                replies = list(workers.map(same_submission, range(8)))
            check(kind + '_parallel_duplicate_one_committed_row', all(r[0] in [200, 201] for r in replies) and total(kind) == 1 and daily(kind) == 1)

            clear()
            connection.execute('update report_submission_private.submission_limits set global_daily_limit=3 where kind=%s', (kind,))
            def distinct_submission(index):
                return submit(kind, 'parallel-distinct-' + str(index), ['anon', 'A', 'B'][index % 3])
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
                replies = list(workers.map(distinct_submission, range(12)))
            check(kind + '_parallel_distinct_exact_limit', sum(r[0] in [200, 201] for r in replies) == 3 and sum(limit_reply(r) for r in replies) == 9 and total(kind) == 3 and daily(kind) == 3)

        clear()
        status, _, _ = submit('shop_information', 'long', value={**payload('shop_information', 'long'), 'description': 'a' * 4001})
        check('oversized_information_report_rejected', status == 400 and total('shop_information') == 0)

        clear()
        original = payload('shop_information', 'normalized')
        first = submit('shop_information', 'normalized', value=original)
        second = submit('shop_information', 'normalized', 'B', value={**original, 'id': str(uuid.uuid4()), 'shop_name': 'Another supplied name', 'wrong_fields': ['phone', 'address', 'phone'], 'description': '  ' + original['description'] + '\n', 'created_at': '2099-01-01T00:00:00Z'})
        check('information_field_order_name_and_whitespace_cannot_bypass_duplicate', first[0] == 201 and second[0] == 201 and total('shop_information') == 1 and daily('shop_information') == 1)

        # 장소 링크 강제 검증은 verified_place_report_access.sql 및 내부 함수 테스트에서 확인한다.
        counter_text = query('select coalesce(jsonb_agg(to_jsonb(c)),\'[]\')::text from report_submission_private.submission_counters c')
        recent_text = query('select coalesce(jsonb_agg(to_jsonb(c)),\'[]\')::text from report_submission_private.recent_submissions c')
        check('quota_state_contains_no_raw_IP_subject_or_report_content', label not in recent_text and all(a['id'] not in counter_text for a in accounts.values()))

    except BaseException as error:
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        if helper_created:
            clear()
            for table in tables.values():
                connection.execute('drop trigger if exists zz_report_test_capture on public.' + table)
            connection.execute('drop schema report_submission_test cascade')
        for actor in accounts.values():
            call('DELETE', '/auth/v1/admin/users/' + actor['id'], actor='service')
        connection.execute('delete from public.ramen_shops where id=%s', (shop_id,))
        for setting in baseline['settings']:
            connection.execute('update report_submission_private.submission_limits set global_minute_limit=%s,global_daily_limit=%s,actor_minute_limit=%s,actor_daily_limit=%s,enabled=%s where kind=%s', (setting['global_minute_limit'], setting['global_daily_limit'], setting['actor_minute_limit'], setting['actor_daily_limit'], setting['enabled'], setting['kind']))
        final = snapshot()
        restored = baseline == final
        connection.close()
    report = {'cases': cases, 'passed_cases': sum(c['passed'] for c in cases), 'HTTP_requests': requests, 'failure': failure, 'baseline_restored': restored, 'baseline': baseline, 'final': final, 'provider_calls': 0, 'real_notifications': 0, 'production_requests': 0, 'temporary_helper_removed': True}
    Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ['passed_cases', 'HTTP_requests', 'failure', 'baseline_restored', 'provider_calls', 'real_notifications']}))
    if failure or not restored:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
