#!/usr/bin/env python3
"""Verify atomic search budgets and the provider-stubbed staging Edge handler."""
import argparse
import concurrent.futures
import hashlib
import json
import urllib.error
import urllib.request
from pathlib import Path

import psycopg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['config', 'db-url-file', 'db-password-file', 'project-ref', 'output']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    database_url = Path(args.db_url_file).read_text().strip()
    if args.project_ref == 'clbhayqiwjawaawvrhcq' or config['project_ref'] != args.project_ref or args.project_ref not in database_url:
        raise ValueError('This test requires the matching staging project')
    if config['url'].rstrip('/') != f'https://{args.project_ref}.supabase.co':
        raise ValueError('Staging URL mismatch')
    password = Path(args.db_password_file).read_text().strip()
    connection = psycopg.connect(database_url, password=password, autocommit=True, connect_timeout=20)
    cases, requests = [], 0
    failure = None

    def check(name, condition, **details):
        cases.append({'case': name, 'passed': bool(condition), **details})
        if not condition:
            raise AssertionError(name)

    def snapshot():
        return connection.execute("select jsonb_build_object('settings',(select jsonb_agg(to_jsonb(s) order by kind) from place_search_private.budget_settings s),'counters',(select coalesce(jsonb_agg(to_jsonb(c) order by kind,scope,actor_key,window_start),'[]') from place_search_private.budget_counters c),'users',(select count(*) from auth.users),'objects',(select count(*) from storage.objects),'reports',(select count(*) from public.feedback_submissions),'events',(select count(*) from public.shop_events),'notices',(select count(*) from public.shop_operating_notices))").fetchone()[0]

    def reserve(kind, actor=None, client=connection):
        return client.execute('select public.consume_place_search_budget(%s,%s)', (kind, actor)).fetchone()[0]

    def call(path, body, role='anon', headers=None):
        nonlocal requests
        token = config['service_role'] if role == 'service' else config['anon']
        request_headers = {'apikey': token, 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', **(headers or {})}
        request = urllib.request.Request(config['url'].rstrip('/') + path, data=json.dumps(body).encode(), headers=request_headers, method='POST')
        requests += 1
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                status, payload, response_headers = response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            status, payload, response_headers = error.code, error.read(), error.headers
        return status, json.loads(payload), response_headers

    baseline = snapshot()
    if baseline['counters']:
        raise ValueError('Refusing to overwrite existing staging budget counters')
    try:
        for role in ['anon', 'authenticated']:
            for operation in ["select public.consume_place_search_budget('naver_local')", 'select * from place_search_private.budget_settings', 'delete from place_search_private.budget_counters']:
                denied = False
                try:
                    with connection.transaction(force_rollback=True):
                        connection.execute('set local role ' + role)
                        connection.execute(operation)
                except psycopg.errors.InsufficientPrivilege:
                    denied = True
                check(role + '_denied_' + operation.split()[0] + ('_rpc' if 'consume_' in operation else '_private'), denied)
        status, response, _ = call('/rest/v1/rpc/consume_place_search_budget', {'p_kind': 'naver_local'})
        check('anonymous_RPC_denied_over_HTTP', status in [401, 403] and response.get('code') == '42501', http_status=status)

        with connection.transaction(force_rollback=True):
            connection.execute("update place_search_private.budget_settings set client_minute_limit=2 where kind='request'")
            first, second, third = [reserve('request', 'a' * 64) for _ in range(3)]
            check('client_minute_exactly_two_units', first['allowed'] and second['allowed'] and not third['allowed'] and third['scope'] == 'client' and third['retry_after_seconds'] > 0)
            check('client_minute_window_exposed', third.get('window') == 'minute')
            check('other_client_isolated', reserve('request', 'b' * 64)['allowed'])
            counts = connection.execute("select consumed from place_search_private.budget_counters where kind='request' and scope='global_day'").fetchone()[0]
            check('rejected_client_does_not_increment_global_count', counts == 3)
        with connection.transaction(force_rollback=True):
            connection.execute("update place_search_private.budget_settings set client_hour_limit=2 where kind='request'")
            accepted = [reserve('request', 'a' * 64) for _ in range(3)]
            check('client_hour_budget_enforced', [r['allowed'] for r in accepted] == [True, True, False])
            check('client_hour_window_exposed', accepted[-1].get('window') == 'hour')
        with connection.transaction(force_rollback=True):
            connection.execute("update place_search_private.budget_settings set minute_limit=2 where kind='request'")
            replies = [reserve('request', character * 64) for character in ['a', 'b', 'c']]
            check('global_minute_independent_of_client_rotation', [r['allowed'] for r in replies] == [True, True, False] and replies[-1]['scope'] == 'global')
            check('global_minute_window_exposed', replies[-1].get('window') == 'minute')
            count = connection.execute("select count(*) from place_search_private.budget_counters where actor_key=%s", ('c' * 64,)).fetchone()[0]
            check('globally_denied_client_creates_no_counters', count == 0)
        with connection.transaction(force_rollback=True):
            connection.execute("update place_search_private.budget_settings set daily_limit=2 where kind='request'")
            replies = [reserve('request', character * 64) for character in ['a', 'b', 'c']]
            check('global_daily_independent_of_client_rotation', [r['allowed'] for r in replies] == [True, True, False])
            check('global_daily_window_exposed', replies[-1].get('window') == 'day')
            is_kst_midnight = connection.execute("select extract(hour from window_start at time zone 'Asia/Seoul')=0 and extract(minute from window_start at time zone 'Asia/Seoul')=0 from place_search_private.budget_counters where kind='request' and scope='global_day'").fetchone()[0]
            check('daily_window_is_KST_midnight', is_kst_midnight)
        with connection.transaction(force_rollback=True):
            connection.execute("update place_search_private.budget_settings set minute_limit=2,client_hour_limit=2 where kind='request'")
            reserve('request', 'a' * 64)
            reserve('request', 'a' * 64)
            same_client = reserve('request', 'a' * 64)
            other_client = reserve('request', 'b' * 64)
            check('longest_client_window_does_not_poison_global_cache', same_client.get('scope') == 'client' and same_client.get('window') == 'hour' and other_client.get('scope') == 'global' and other_client.get('window') == 'minute')
        with connection.transaction(force_rollback=True):
            connection.execute("insert into place_search_private.budget_counters values ('naver_local','global_day','',date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'-interval '1 day',now()-interval '1 minute',1000)")
            check('expired_previous_day_does_not_block_new_day', reserve('naver_local')['allowed'])
            check('expired_counter_cleanup', connection.execute("select count(*) from place_search_private.budget_counters where expires_at<now()").fetchone()[0] == 0)
        with connection.transaction(force_rollback=True):
            connection.execute("update place_search_private.budget_settings set enabled=false where kind='naver_geocoding'")
            disabled = reserve('naver_geocoding')
            check('server_disable_switch_enforced', not disabled['allowed'] and disabled['reason'] == 'disabled')
            check('disabled_budget_writes_no_counters', connection.execute('select count(*) from place_search_private.budget_counters').fetchone()[0] == 0)
        for kind, actor in [(None, None), ('unknown', None), ('request', None), ('request', 'caller-chosen-raw-IP')]:
            denied = False
            try:
                with connection.transaction(force_rollback=True):
                    reserve(kind, actor)
            except psycopg.errors.InvalidParameterValue:
                denied = True
            check('invalid_budget_input_' + str(kind) + '_' + str(actor is None), denied)

        connection.execute("update place_search_private.budget_settings set daily_limit=3,minute_limit=100 where kind='naver_local'")
        def parallel_unit(_):
            with psycopg.connect(database_url, password=password, autocommit=True, connect_timeout=20) as other:
                other.execute('set role service_role')
                return reserve('naver_local', client=other)['allowed']
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            admitted = list(workers.map(parallel_unit, range(12)))
        check('twelve_concurrent_requests_cannot_exceed_three_units', sum(admitted) == 3, admitted=sum(admitted), requested=12)
        count = connection.execute("select consumed from place_search_private.budget_counters where kind='naver_local' and scope='global_day'").fetchone()[0]
        check('concurrent_daily_counter_exact', count == 3)

        connection.execute('delete from place_search_private.budget_counters')
        connection.execute("update place_search_private.budget_settings set minute_limit=100,daily_limit=100,client_minute_limit=100,client_hour_limit=100 where kind='request'")
        connection.execute("update place_search_private.budget_settings set daily_limit=2 where kind in ('naver_local','naver_geocoding')")
        endpoint = '/functions/v1/security-place-search-budget'
        for query, kind in [('서울특별시 강남구 테헤란로 123', 'naver_geocoding'), ('서울역', 'naver_local')]:
            for index in range(3):
                status, response, headers = call(endpoint, {'query': query, 'center': {'lat': 37, 'lng': 127}})
                if index < 2:
                    expected = status == 200 and isinstance(response.get('results'), list)
                else:
                    expected = status == 429 and response.get('code') == 'search_rate_limited' and int(headers.get('Retry-After', '0')) > 0
                    check(kind + '_Edge_daily_window_and_wait_time', response.get('limit_window') == 'day' and response.get('retry_after_seconds') == int(headers.get('Retry-After', '0')))
                check(kind + '_edge_attempt_' + str(index + 1), expected, http_status=status, code=response.get('code'))
            count = connection.execute("select consumed from place_search_private.budget_counters where kind=%s and scope='global_day'", (kind,)).fetchone()[0]
            check(kind + '_Edge_provider_attempts_capped_at_two', count == 2)
        for actor in ['203.0.113.1', '203.0.113.2']:
            status, response, _ = call(endpoint, {'query': '서울역', 'center': {'lat': 37, 'lng': 127}, 'actor_key': actor}, headers={'x-forwarded-for': actor})
            check('forged_actor_still_cannot_exceed_global_provider_budget_' + actor[-1], status == 429 and response.get('code') == 'search_rate_limited', http_status=status)
        status, _, _ = call(endpoint, {})
        check('invalid_Edge_input_rejected', status == 400, http_status=status)
        status, _, _ = call(endpoint, {'query': '서울역', 'center': {'lat': 37, 'lng': 127}, 'padding': 'x' * 5000})
        check('oversized_Edge_input_rejected', status == 413, http_status=status)
        check('business_rows_unchanged', all(snapshot()[key] == baseline[key] for key in ['users','objects','reports','events','notices']))
    except BaseException as error:
        failure = f'{type(error).__name__}: {error}'
    finally:
        connection.execute('delete from place_search_private.budget_counters')
        for setting in baseline['settings']:
            connection.execute('update place_search_private.budget_settings set minute_limit=%s,daily_limit=%s,client_minute_limit=%s,client_hour_limit=%s,enabled=%s where kind=%s', (setting['minute_limit'],setting['daily_limit'],setting['client_minute_limit'],setting['client_hour_limit'],setting['enabled'],setting['kind']))
        final = snapshot()
        restored = final == baseline
        report = {'project':'staging','cases':cases,'passed_cases':sum(c['passed'] for c in cases),'http_requests':requests,'failure':failure,'cleanup_restored_baseline':restored,'baseline':baseline,'final':final,'provider_calls':0,'production_requests':0,'auth_sessions_created':0}
        Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        connection.close()
    print(json.dumps({k:report[k] for k in ['passed_cases','http_requests','failure','cleanup_restored_baseline','provider_calls','production_requests']},ensure_ascii=False))
    if failure or not restored:
        raise AssertionError('See the sanitized staging test results')


if __name__ == '__main__':
    main()
