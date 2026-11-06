#!/usr/bin/env python3
"""Hosted staging에서 영업 상태의 공개 컬럼 경계와 기존 워커 저장 계약을 검증한다."""
import argparse
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import psycopg

REF = 'gedptwzjortijxpjvmbc'
TABLE = 'shop_operating_status'
VIEW = 'shop_operating_status_public'
PUBLIC = {'shop_id', 'status', 'checked_at'}
PRIVATE = {'naver_place_id', 'source_url', 'last_error', 'next_check_at',
           'check_interval_minutes', 'check_reason', 'consecutive_failures'}
MARKER = 'SYNTHETIC_INTERNAL_DIAGNOSTIC_ONLY'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=['before', 'prepare', 'after', 'cleanup'], required=True)
    for name in ['config', 'db-url-file', 'db-password-file', 'state', 'output']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    db_url = Path(args.db_url_file).read_text().strip()
    assert config['project_ref'] == REF and REF in db_url
    assert config['url'].rstrip('/') == f'https://{REF}.supabase.co', '합성 검사는 staging에서만 실행합니다'
    password = Path(args.db_password_file).read_text().strip()
    connection = psycopg.connect(db_url, password=password, autocommit=True, connect_timeout=20)
    connection.execute("set statement_timeout='10s'")
    state_path = Path(args.state)
    if args.phase in ['before', 'prepare']:
        assert not state_path.exists(), '진행 중인 검사 상태를 덮어쓰지 않습니다'
        state = {'project_ref': REF, 'users': {}, 'shops': [], 'before_cases': [], 'before_requests': 0}
    else:
        state = json.loads(state_path.read_text())
    assert state['project_ref'] == REF
    opener = urllib.request.build_opener(NoRedirect)
    cases = []
    requests = 0
    failure = None
    keep = False

    def query(sql, params=()):
        return connection.execute(sql, params or None).fetchone()[0]

    def check(name, condition, **details):
        cases.append({'case': name, 'passed': bool(condition), **details})
        assert condition, name

    def save_state():
        descriptor = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            json.dump(state, output)
        state_path.chmod(0o600)

    def call(method, path, body=None, actor='anon', headers=None):
        nonlocal requests
        requests += 1
        key = config['service_role'] if actor == 'service' else config['anon']
        token = key if actor in ['service', 'anon'] else state['users'][actor]['token']
        request = urllib.request.Request(config['url'].rstrip('/') + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'apikey': key, 'Authorization': 'Bearer ' + token,
                     'Content-Type': 'application/json', **(headers or {})})
        try:
            response = opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = response.read()
            return response.status, json.loads(body) if body else None

    def path(table=TABLE, **params):
        return '/rest/v1/' + table + ('?' + urllib.parse.urlencode(params) if params else '')

    def denied(reply):
        return reply[0] in [401, 403] and isinstance(reply[1], dict) and reply[1].get('code') == '42501'

    def public_row(reply, count=1):
        return reply[0] == 200 and isinstance(reply[1], list) and len(reply[1]) == count and all(set(row) == PUBLIC for row in reply[1])

    def snapshot():
        return query("""select jsonb_build_object(
            'shops',(select jsonb_build_object('rows',count(*),'digest',encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(s) order by id)::text,'[]'),'sha256'),'hex')) from public.ramen_shops s),
            'statuses',(select jsonb_build_object('rows',count(*),'digest',encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(s) order by shop_id)::text,'[]'),'sha256'),'hex')) from public.shop_operating_status s),
            'auth_users',(select count(*) from auth.users),'profiles',(select count(*) from public.public_profiles),
            'storage',(select count(*) from storage.objects),'pushes',(select count(*) from public.push_registrations))""")

    def record(shop, status='영업 중', error=MARKER):
        return {'shop_id': shop, 'naver_place_id': '99990001', 'status': status,
                'source_url': 'https://example.invalid/synthetic-status',
                'checked_at': '2026-10-13T00:00:00+00:00', 'last_error': error,
                'next_check_at': '2030-01-01T00:00:00+00:00', 'check_interval_minutes': 60,
                'check_reason': 'retry', 'consecutive_failures': 2}

    def cleanup():
        if state['shops']:
            connection.execute('delete from public.ramen_shops where id=any(%s::uuid[])', (state['shops'],))
        for user in state['users'].values():
            reply = call('DELETE', '/auth/v1/admin/users/' + user['id'], actor='service')
            check('합성 계정과 세션을 제거한다', reply[0] in [200, 404])
        final = snapshot()
        check('모든 합성 자료 제거 후 기존 집계와 내용을 복원한다', final == state['baseline'])
        return final

    try:
        assert query('select count(*) from cron.job where active') == 0
        assert query("select count(*) from pg_trigger t join pg_proc p on p.oid=t.tgfoid where t.tgrelid in ('public.ramen_shops'::regclass,'public.shop_operating_status'::regclass) and not t.tgisinternal and p.prosrc~*'(net.http|http_post|http_get|webhook|send_notification)'") == 0
        if args.phase in ['before', 'prepare']:
            state['baseline'] = snapshot()
            assert state['baseline']['shops']['rows'] == state['baseline']['statuses']['rows'] == 0
            save_state()
            for actor in ['A', 'B']:
                email = f'status.{uuid.uuid4().hex}.{actor}@example.invalid'
                new_password = secrets.token_urlsafe(30)
                reply = call('POST', '/auth/v1/admin/users', {'email': email, 'password': new_password,
                    'email_confirm': True, 'user_metadata': {'role': 'service_role', 'is_admin': True}}, 'service')
                check(actor + ' 합성 계정을 생성한다', reply[0] == 200 and bool(reply[1].get('id')))
                state['users'][actor] = {'id': reply[1]['id']}
                save_state()
                reply = call('POST', '/auth/v1/token?grant_type=password', {'email': email, 'password': new_password})
                check(actor + ' 한 번 로그인한 세션을 재사용한다', reply[0] == 200 and bool(reply[1].get('access_token')))
                state['users'][actor]['token'] = reply[1]['access_token']
                save_state()
            state['shops'] = [str(uuid.uuid4()) for _ in range(3)]
            save_state()
            for number, shop in enumerate(state['shops']):
                connection.execute("insert into public.ramen_shops(id,name,address,lat,lng,is_visible,naver_place_url,menu_snapshot_enabled) values (%s,%s,'Synthetic only',37,127,%s,%s,false)",
                    (shop, 'Synthetic status ' + str(number), number != 1,
                     'https://map.naver.com/p/entry/place/99990001' if number != 2 else None))
            for shop in state['shops'][:2]:
                data = record(shop)
                connection.execute("insert into public.shop_operating_status(shop_id,naver_place_id,status,source_url,checked_at,last_error,next_check_at,check_interval_minutes,check_reason,consecutive_failures) values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)", tuple(data.values()))
            if args.phase == 'before':
                for actor in ['anon', 'A', 'B']:
                    reply = call('GET', path(shop_id='eq.' + state['shops'][0]), actor=actor)
                    check(actor + ' 수정 전 전체 조회에 내부 진단 값이 포함된다',
                          reply[0] == 200 and len(reply[1]) == 1 and set(reply[1][0]) == PUBLIC | PRIVATE and reply[1][0]['last_error'] == MARKER,
                          http_status=reply[0])
            state['fixture_snapshot'] = snapshot()
            state['before_cases'] = cases
            state['before_requests'] = requests
            save_state()
            keep = True
        elif args.phase == 'after':
            visible, hidden, spare = state['shops']
            public_select = ','.join(sorted(PUBLIC))
            fixture = snapshot()
            check('권한 migration은 기존 합성 데이터도 변경하지 않는다', fixture == state['fixture_snapshot'])
            for actor in ['anon', 'A', 'B']:
                reply = call('GET', path(shop_id='eq.' + visible), actor=actor)
                check(actor + ' 원본 wildcard 조회를 거절한다', denied(reply), http_status=reply[0])
                reply = call('GET', path(shop_id='eq.' + visible, select=public_select), actor=actor)
                check(actor + ' 원본의 명시적 공개 세 필드만 읽는다', public_row(reply) and reply[1][0]['status'] == '영업 중')
                reply = call('GET', path(VIEW, shop_id='eq.' + visible), actor=actor)
                check(actor + ' 공개 뷰 wildcard는 세 필드만 반환한다', public_row(reply) and reply[1][0]['shop_id'] == visible)
                for table in [TABLE, VIEW]:
                    reply = call('GET', path(table, shop_id='eq.' + hidden, select=public_select), actor=actor)
                    check(actor + ' ' + table + ' 숨김 가게는 보이지 않는다', reply == (200, []))
                for column in sorted(PRIVATE):
                    reply = call('GET', path(shop_id='eq.' + visible, select='shop_id,' + column), actor=actor)
                    check(actor + ' 내부 컬럼 ' + column + ' 직접 조회를 거절한다', denied(reply), http_status=reply[0])
                for parameters in [{'last_error': 'eq.' + MARKER}, {'order': 'next_check_at.desc'}, {'consecutive_failures': 'gt.0'}]:
                    reply = call('GET', path(shop_id='eq.' + visible, select=public_select, **parameters), actor=actor)
                    check(actor + ' 내부 컬럼 필터나 정렬로 값을 추측할 수 없다', denied(reply), http_status=reply[0])
                reply = call('GET', path(VIEW, shop_id='eq.' + visible, select='shop_id,last_error'), actor=actor)
                check(actor + ' 공개 뷰에 내부 컬럼을 지정해도 읽을 수 없다', reply[0] == 400 and reply[1].get('code') == '42703')
                reply = call('GET', path('ramen_shops', id='eq.' + visible, select='id,shop_operating_status(*)'), actor=actor)
                check(actor + ' 부모 관계의 원본 wildcard도 거절한다', denied(reply), http_status=reply[0])
                for related in [TABLE, VIEW]:
                    reply = call('GET', path('ramen_shops', id='eq.' + visible, select='id,' + related + '(' + public_select + ')'), actor=actor)
                    nested = reply[1][0].get(related) if reply[0] == 200 and len(reply[1]) == 1 else None
                    nested = nested if isinstance(nested, list) else [nested]
                    check(actor + ' 부모 관계에서도 공개 세 필드만 읽는다', all(isinstance(row, dict) and set(row) == PUBLIC for row in nested) and len(nested) == 1)
                for method in ['POST', 'PATCH', 'DELETE']:
                    body = record(spare) if method == 'POST' else {'status': 'UNAUTHORIZED'} if method == 'PATCH' else None
                    reply = call(method, path(**({} if method == 'POST' else {'shop_id': 'eq.' + visible})), body, actor,
                                 {'Prefer': 'return=minimal'})
                    check(actor + ' 원본 ' + method + ' 쓰기를 거절한다', denied(reply), http_status=reply[0])
                reply = call('POST', '/rest/v1/rpc/claim_due_shop_operating_statuses', {'batch_limit': 1}, actor)
                check(actor + ' 앞서 닫은 워커 선점 권한도 유지된다', denied(reply), http_status=reply[0])
            check('거절과 공개 조회 뒤 원본 데이터는 그대로다', snapshot() == fixture)

            for actor in ['anon', 'A', 'B', 'service']:
                for method in ['POST', 'PATCH', 'DELETE']:
                    body = {'shop_id': spare, 'status': 'UNAUTHORIZED', 'checked_at': '2026-10-13T00:00:00Z'} if method == 'POST' else {'status': 'UNAUTHORIZED'} if method == 'PATCH' else None
                    reply = call(method, path(VIEW, **({} if method == 'POST' else {'shop_id': 'eq.' + visible})), body, actor,
                                 {'Prefer': 'return=representation'})
                    check(actor + ' 공개 뷰 ' + method + '는 쓰기 전용 경로로 사용할 수 없다', denied(reply), http_status=reply[0])
            reply = call('GET', path(VIEW, shop_id='eq.invalid'), actor='anon')
            check('공개 뷰의 잘못된 UUID는 입력 오류다', reply[0] == 400 and reply[1].get('code') == '22P02')
            reply = call('GET', path(VIEW, shop_id='eq.' + str(uuid.uuid4())), actor='anon')
            check('없는 가게는 공개 뷰에서 빈 배열이다', reply == (200, []))

            for role in ['anon', 'authenticated']:
                for statement in ['select * from public.shop_operating_status',
                                  'select to_jsonb(s) from public.shop_operating_status s',
                                  'select last_error from public.shop_operating_status']:
                    with connection.transaction():
                        connection.execute('set local role ' + role)
                        try:
                            connection.execute(statement).fetchall()
                        except psycopg.errors.InsufficientPrivilege:
                            blocked = True
                        else:
                            blocked = False
                        check(role + ' SQL 전체 행과 내부 진단 조회도 거절한다', blocked)
                        raise psycopg.Rollback
                with connection.transaction():
                    connection.execute('set local role ' + role)
                    rows = connection.execute('select * from public.shop_operating_status_public').fetchall()
                    check(role + ' SQL 공개 뷰는 보이는 가게 한 건만 반환한다', len(rows) == 1 and len(rows[0]) == 3)
                    raise psycopg.Rollback

            for actor in ['anon', 'A']:
                reply = call('POST', '/graphql/v1', {'query': '{__schema{types{name fields{name}}}}'}, actor)
                extension_enabled = query("select exists(select 1 from pg_extension where extname='pg_graphql')")
                if not extension_enabled:
                    check(actor + ' 비활성 GraphQL 경로는 테이블 자료를 반환하지 않는다',
                          reply[0] == 200 and reply[1] == {'errors': [{'message': 'pg_graphql extension is not enabled.'}]})
                else:
                    check(actor + ' GraphQL 스키마 권한 검사를 실행한다', reply[0] == 200 and 'data' in reply[1])
                    types = reply[1]['data']['__schema']['types']
                    status_types = [item for item in types if item['name'].replace('_', '').lower() == 'shopoperatingstatus']
                    exposed = {field['name'].replace('_', '').lower() for item in status_types for field in item['fields'] or []}
                    private_names = {name.replace('_', '').lower() for name in PRIVATE}
                    check(actor + ' GraphQL에서도 내부 진단 컬럼을 노출하지 않는다', not exposed & private_names,
                          table_type_exposed=bool(status_types), exposed_fields=sorted(exposed))

            reply = call('GET', path(), actor='service')
            check('서버 원본 조회는 숨김 가게와 열 개 필드를 유지한다', reply[0] == 200 and len(reply[1]) == 2 and all(set(row) == PUBLIC | PRIVATE for row in reply[1]) and {row['shop_id'] for row in reply[1]} == {visible, hidden})
            reply = call('GET', path(VIEW), actor='service')
            check('서버가 공개 뷰를 읽어도 응답은 세 필드다', public_row(reply, 2))
            reply = call('POST', path(on_conflict='shop_id'), record(spare, error=None), 'service',
                         {'Prefer': 'resolution=merge-duplicates,return=representation'})
            check('기존 워커 주소의 새 성공 결과 upsert가 정상이다', reply[0] == 201 and len(reply[1]) == 1 and reply[1][0]['last_error'] is None and reply[1][0]['status'] == '영업 중')
            failed = record(spare, error=MARKER + '_RETRY')
            del failed['status']
            reply = call('POST', path(on_conflict='shop_id'), failed, 'service',
                         {'Prefer': 'resolution=merge-duplicates,return=representation'})
            check('워커 실패 upsert는 내부 오류를 저장하고 기존 영업 상태를 유지한다', reply[0] in [200, 201] and reply[1][0]['last_error'] == MARKER + '_RETRY' and reply[1][0]['status'] == '영업 중')
            reply = call('PATCH', path(shop_id='eq.' + spare), {'check_reason': 'pre_open', 'next_check_at': '2030-01-02T00:00:00Z'}, 'service', {'Prefer': 'return=representation'})
            check('기존 워커 주소의 예약 PATCH가 정상이다', reply[0] == 200 and len(reply[1]) == 1 and reply[1][0]['check_reason'] == 'pre_open')
            reply = call('GET', path(VIEW, shop_id='eq.' + spare))
            check('서버가 진단 값을 갱신해도 공개 응답은 세 필드다', public_row(reply) and MARKER not in json.dumps(reply[1]))
            reply = call('DELETE', path(shop_id='eq.' + spare), actor='service', headers={'Prefer': 'return=representation'})
            check('서버의 원본 삭제와 반환 계약을 유지한다', reply[0] == 200 and len(reply[1]) == 1 and reply[1][0]['shop_id'] == spare)
            check('원본 삭제는 공개 뷰에도 반영된다', call('GET', path(VIEW, shop_id='eq.' + spare)) == (200, []))
            connection.execute("update public.shop_operating_status set next_check_at=now()-interval '1 minute' where shop_id=any(%s::uuid[])", ([visible, hidden],))
            reply = call('POST', '/rest/v1/rpc/claim_due_shop_operating_statuses', {'batch_limit': 50}, 'service')
            check('서버 선점은 공개 가게만 반환하고 기존 계약을 유지한다', reply[0] == 200 and len(reply[1]) == 1 and reply[1][0]['id'] == visible and len(reply[1][0]) == 8)
            check('서버 선점 후 즉시 재전송은 중복 작업이 없다', call('POST', '/rest/v1/rpc/claim_due_shop_operating_statuses', {'batch_limit': 50}, 'service') == (200, []))
            check('선점 예약 정보는 원본에 유지된다', query("select check_reason='running' and next_check_at>now()+interval '59 minutes' from public.shop_operating_status where shop_id=%s", (visible,)))
            before_rollback = snapshot()
            with connection.transaction():
                connection.execute('set local role service_role')
                connection.execute("update public.shop_operating_status set last_error='SYNTHETIC_ROLLBACK' where shop_id=%s", (visible,))
                raise psycopg.Rollback
            check('서버 진단 값 변경의 트랜잭션 취소는 원본을 복원한다', snapshot() == before_rollback)
            connection.execute('update public.ramen_shops set is_visible=false where id=%s', (visible,))
            check('공개 가게를 숨기면 같은 세션의 공개 뷰에서도 사라진다', call('GET', path(VIEW, shop_id='eq.' + visible), actor='A') == (200, []))
            connection.execute('update public.ramen_shops set is_visible=true where id=%s', (visible,))
            check('가게를 다시 공개하면 세 필드 조회가 복구된다', public_row(call('GET', path(VIEW, shop_id='eq.' + visible), actor='A')))
            check('뷰는 호출자 권한으로 RLS를 적용한다', query("select 'security_invoker=true'=any(reloptions) from pg_class where oid='public.shop_operating_status_public'::regclass"))
        else:
            check('중단된 합성 자료 정리를 실행한다', True)
    except Exception as error:
        failure = type(error).__name__ + (': ' + str(error) if isinstance(error, AssertionError) else '')
        keep = False
    finally:
        final = None
        if not keep and 'baseline' in state:
            try:
                final = cleanup()
                state_path.unlink(missing_ok=True)
            except Exception as error:
                failure = (failure + '; ' if failure else '') + 'cleanup ' + type(error).__name__
                save_state()
        report = {'phase': args.phase, 'cases': cases, 'passed_cases': sum(case['passed'] for case in cases),
                  'HTTP_requests': requests, 'failure': failure, 'baseline': state.get('baseline'), 'final': final,
                  'baseline_restored': final == state.get('baseline') if final else False,
                  'fixture_retained_for_migration': keep, 'before_passed_cases': sum(case['passed'] for case in state['before_cases']),
                  'before_HTTP_requests': state['before_requests'], 'password_logins': 2 if args.phase in ['before', 'prepare'] else 0,
                  'actual_provider_calls': 0, 'actual_notifications': 0, 'production_requests': 0}
        Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({key: value for key, value in report.items() if key not in ['cases', 'baseline', 'final']}, ensure_ascii=False))
        connection.close()
    if failure:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
