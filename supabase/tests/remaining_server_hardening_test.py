"""Hosted staging에서 남은 서버 계약과 읽기 전용 검증 RPC를 확인한다."""
import concurrent.futures
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/security-api/snapshot/fix-remaining-hardening-20261013/staging-db-verification.json'
PRIVATE = Path.home() / '.config/ramap-security-audit'
REF = 'gedptwzjortijxpjvmbc'
CONFIG = json.loads((PRIVATE / 'staging-remaining-rpc-20261012.json').read_text())
URL = Path('/private/tmp/ramap-security-staging-cli/supabase/.temp/pooler-url').read_text().strip()
assert CONFIG['project_ref'] == REF and REF in URL and CONFIG['url'] == 'https://' + REF + '.supabase.co'
PASSWORD = (PRIVATE / 'staging-db-password').read_text().strip()
CASES, REQUESTS, IDS = [], [], []
USER = TOKEN = None
CREATED_VAULT = []
STATE = Path('/private/tmp/ramap-remaining-hardening-state.json')
TABLES = ['ramen_shops', 'shop_menu_sections', 'shop_menu_items', 'shop_menu_update_timestamps',
          'shop_menu_snapshots', 'shop_menu_change_events', 'shop_menu_validation_runs']
CONNECTION = psycopg.connect(URL, password=PASSWORD, autocommit=True, connect_timeout=20)
CONNECTION.execute("set statement_timeout='10s'")


def check(name, valid, **details):
    CASES.append({'case': name, 'passed': bool(valid), **details})
    assert valid, name


def query(sql, params=None):
    return CONNECTION.execute(sql, params).fetchone()[0]


def save_state():
    with os.fdopen(os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
        json.dump({'project_ref': REF, 'shops': IDS, 'user': USER, 'vault_ids': CREATED_VAULT}, f)


def call(path, payload=None, actor='service', method='POST', raw=None):
    time.sleep(.15)
    key = CONFIG['service_role'] if actor == 'service' else CONFIG['anon']
    token = key if actor in ['service', 'anon'] else TOKEN if actor == 'member' else 'invalid-test-token'
    data = raw if raw is not None else json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(CONFIG['url'] + path, data=data, method=method,
        headers={'apikey': key, 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        reply = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        reply = error
    with reply:
        body = reply.read()
        try:
            result = json.loads(body) if body else None
        except json.JSONDecodeError:
            result = None
        REQUESTS.append({'path': path.split('?')[0], 'method': method, 'actor': actor, 'status': reply.status})
        return reply.status, result


def rpc(name, payload, actor='service', method='POST'):
    path = '/rest/v1/rpc/' + name
    if method == 'GET':
        params = {k: json.dumps(v, separators=(',', ':')) if isinstance(v, (dict, list, bool)) or v is None else v for k, v in payload.items()}
        return call(path + '?' + urllib.parse.urlencode(params), actor=actor, method='GET')
    return call(path, payload, actor)


def snapshot():
    result = {}
    for table in TABLES:
        result[table] = query('select jsonb_build_object(\'rows\',count(*),\'digest\',md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,\'[]\'))) from public.' + table + ' t')
    result['users'] = query('select count(*) from auth.users')
    result['profiles'] = query('select count(*) from public.public_profiles')
    return result


def shop(waiting=True, visible=True):
    ident = str(uuid.uuid4())
    IDS.append(ident)
    save_state()
    CONNECTION.execute("insert into public.ramen_shops(id,name,address,lat,lng,menu_snapshot_enabled,is_visible,waiting_provider) values(%s,'hardening synthetic','test-only',37,127,false,%s,%s)",
                       (ident, visible, 'synthetic' if waiting else None))
    return ident


def menu(ident):
    section = query("insert into public.shop_menu_sections(shop_id,title) values(%s,'합성 메뉴') returning id", (ident,))
    item = query("insert into public.shop_menu_items(section_id,name,price_krw) values(%s,'합성 라멘',10000) returning id", (section,))
    return str(section), str(item)


def setup():
    global USER, TOKEN
    assert not STATE.exists(), '이전 실행의 fixture 상태부터 정리해야 합니다'
    email = 'hardening-' + uuid.uuid4().hex + '@example.invalid'
    password = secrets.token_urlsafe(32)
    status, body = call('/auth/v1/admin/users', {'email': email, 'password': password, 'email_confirm': True})
    check('합성 계정 한 개 생성', status in [200, 201])
    USER = body['id']
    save_state()
    status, body = call('/auth/v1/token?grant_type=password', {'email': email, 'password': password}, 'anon')
    check('합성 계정은 한 번만 로그인하고 세션 재사용', status == 200 and 'access_token' in body)
    TOKEN = body['access_token']


def search_path_tests():
    names = ['normalize_menu_duplicate_key', 'event_is_active_on', 'event_is_today_on', 'update_updated_at_column']
    configs = CONNECTION.execute("select proname,proconfig from pg_proc where pronamespace='public'::regnamespace and proname=any(%s)", (names,)).fetchall()
    check('네 함수의 search_path가 빈 경로로 고정', len(configs) == 4 and all(x[1] == ['search_path=""'] for x in configs))
    with CONNECTION.transaction():
        CONNECTION.execute("set local search_path = pg_temp")
        check('호출자 경로가 달라도 메뉴 이름 정규화 유지', query("select public.normalize_menu_duplicate_key('  돈코츠 RAMEN ')") == '돈코츠')
        check('기존 행사 활성 판정 유지', query("select public.event_is_active_on('collab','2026-10-01','2026-10-13','2026-10-13') and not public.event_is_active_on('collab','2026-10-01','2026-10-13','2026-10-14')"))
        check('기존 당일과 리뉴얼 한 달 경계 유지', query("select public.event_is_today_on('collab','2026-10-01','2026-10-13','2026-10-01') and not public.event_is_today_on('store_renewal','2026-10-01',null,'2026-11-01')"))


def menu_validation_tests():
    ident = shop()
    payload = {'p_run_id': None, 'p_shop_id': ident, 'p_menu_fingerprint': 'a' * 64, 'p_source_hash': 'b' * 64,
               'p_menu_items': [{'name': '합성 메뉴'}], 'p_raw_dom': 'x' * 100,
               'p_source_url': 'https://example.invalid/menu', 'p_parser_version': 'synthetic-v1', 'p_change_summary': {}}
    name = 'record_shop_menu_validation_observation'
    for actor, expected in [('anon', 401), ('member', 403)]:
        status, _ = rpc(name, payload, actor)
        check(actor + ' 메뉴 수집 RPC 접근 거절', status == expected)
    status, body = rpc(name, payload)
    check('정상 입력의 기존 no_snapshot 응답', status == 200 and body == 'no_snapshot')
    invalid = [(key + ' SQL NULL', {key: None}) for key in payload if key != 'p_run_id']
    invalid += [('빈 메뉴 배열', {'p_menu_items': []}), ('메뉴 객체', {'p_menu_items': {}}),
                ('짧은 fingerprint', {'p_menu_fingerprint': 'a' * 63}), ('잘못된 source hash', {'p_source_hash': 'z' * 64}),
                ('짧은 원문', {'p_raw_dom': 'x' * 99}), ('빈 출처', {'p_source_url': '  '}), ('빈 parser', {'p_parser_version': ''})]
    for phase in ['no_snapshot', 'unchanged', 'changed']:
        if phase == 'unchanged':
            CONNECTION.execute('insert into public.shop_menu_snapshots(shop_id,source_url,parser_version,source_hash,raw_dom,menu_items,menu_fingerprint) values(%s,%s,%s,%s,%s,%s,%s)',
                (ident, payload['p_source_url'], payload['p_parser_version'], payload['p_source_hash'], payload['p_raw_dom'], Jsonb(payload['p_menu_items']), payload['p_menu_fingerprint']))
        if phase == 'changed':
            payload['p_menu_fingerprint'] = 'c' * 64
        original = snapshot()
        for label, patch in invalid:
            status, body = rpc(name, {**payload, **patch})
            check(phase + ': ' + label + '는 통제된400', status == 400 and body.get('code') == 'P0001' and body.get('message') == 'invalid validated menu observation', http_status=status)
        check(phase + ': 모든 거절 뒤 데이터 불변', snapshot() == original)
        if phase == 'unchanged':
            status, body = rpc(name, payload)
            check('정상 동일 fingerprint는 unchanged와 무변경', status == 200 and body == 'unchanged' and snapshot() == original)
    status, body = rpc(name, payload)
    check('정상 변경은 snapshot과 event를 함께 저장', status == 200 and body == 'applied' and query('select count(*) from public.shop_menu_snapshots where shop_id=%s', (ident,)) == 2 and query('select count(*) from public.shop_menu_change_events where shop_id=%s', (ident,)) == 1)
    original = snapshot()
    status, body = rpc(name, {**payload, 'p_menu_fingerprint': 'd' * 64, 'p_run_id': str(uuid.uuid4())})
    check('잘못된 실행 ID의 FK 실패는 전체 rollback', status == 409 and body.get('code') == '23503' and snapshot() == original)
    minimal = {k: v for k, v in payload.items() if k != 'p_change_summary'}
    status, body = rpc(name, minimal)
    check('생략한 change_summary 기본값과 null run_id 호환', status == 200 and body == 'unchanged')


def cascade_and_view_tests():
    ident, hidden = shop(), shop(visible=False)
    section, item = menu(ident)
    menu(hidden)
    check('메뉴 생성은 timestamp를 생성', query('select count(*) from public.shop_menu_update_timestamps where shop_id=%s', (ident,)) == 1)
    CONNECTION.execute("update public.shop_menu_update_timestamps set updated_at='2000-01-01' where shop_id=%s", (ident,))
    CONNECTION.execute("update public.shop_menu_items set name='변경 메뉴' where id=%s", (item,))
    check('메뉴 수정은 timestamp를 갱신', query("select updated_at > '2026-01-01' from public.shop_menu_update_timestamps where shop_id=%s", (ident,)))
    CONNECTION.execute("update public.shop_menu_update_timestamps set updated_at='2000-01-01' where shop_id=%s", (ident,))
    CONNECTION.execute('delete from public.shop_menu_sections where id=%s', (section,))
    check('부모가 있는 섹션 삭제는 메뉴만 정리하고 timestamp 갱신', query('select count(*) from public.shop_menu_items where id=%s', (item,)) == 0 and query("select updated_at > '2026-01-01' from public.shop_menu_update_timestamps where shop_id=%s", (ident,)))
    section, item = menu(ident)
    original = snapshot()
    for actor in ['anon', 'member', 'service']:
        status, body = call('/rest/v1/shop_waiting_systems?select=id,shop_id,provider,provider_url&shop_id=eq.' + ident, actor=actor, method='GET')
        check(actor + ' 대기 시스템 조회 계약 보존', status == 200 and len(body) == 1 and body[0]['shop_id'] == ident)
        status, body = call('/rest/v1/shop_waiting_systems?select=id&shop_id=eq.' + hidden, actor=actor, method='GET')
        check(actor + ' 숨김 매장 경계 보존', status == 200 and len(body) == (1 if actor == 'service' else 0))
        for method, body in [('POST', {'id': str(uuid.uuid4()), 'provider': 'synthetic'}), ('PATCH', {'provider': 'changed'}), ('DELETE', None)]:
            path = '/rest/v1/shop_waiting_systems' + ('' if method == 'POST' else '?shop_id=eq.' + ident)
            status, _ = call(path, body, actor, method)
            check(actor + ' 조회뷰 ' + method + ' 차단', status == (401 if actor == 'anon' else 403))
    check('조회뷰의 쓰기 거절은 모든 데이터 보존', snapshot() == original)
    status, _ = call('/rest/v1/ramen_shops?id=eq.' + ident, {'waiting_provider': 'updated'}, method='PATCH')
    check('서비스의 원본 매장 수정 유지', status == 204 and query('select waiting_provider from public.ramen_shops where id=%s', (ident,)) == 'updated')
    check('고정 search_path의 updated_at 트리거 유지', query('select updated_at >= created_at from public.ramen_shops where id=%s', (ident,)))
    status, _ = call('/rest/v1/ramen_shops?id=eq.' + ident, method='DELETE')
    check('메뉴가 있는 매장 삭제 성공', status == 204)
    check('매장 삭제의 section/item/timestamp 모두 정리', query('select count(*) from public.ramen_shops where id=%s', (ident,)) == 0 and query('select count(*) from public.shop_menu_sections where id=%s', (section,)) == 0 and query('select count(*) from public.shop_menu_items where id=%s', (item,)) == 0 and query('select count(*) from public.shop_menu_update_timestamps where shop_id=%s', (ident,)) == 0)


def jobs():
    return query("select coalesce(jsonb_agg(jsonb_build_object('id',jobid,'name',jobname,'schedule',schedule,'command_hash',md5(command)) order by jobname),'[]') from cron.job where jobname in('event-notification-day-before','event-notification-event-day')")


def cron_tests():
    assert jobs() == []
    assert query("select count(*) from vault.secrets where name in('project_url','event_notification_cron_secret')") == 0
    for name, value in [('project_url', CONFIG['url'] + '/functions/v1/hardening-nonexistent-sink'), ('event_notification_cron_secret', secrets.token_urlsafe(32))]:
        CREATED_VAULT.append(str(query('select vault.create_secret(%s,%s,%s)', (value, name, 'Temporary hardening test; no provider'))))
        save_state()
    for actor, expected in [('anon', 401), ('member', 403)]:
        check(actor + ' 예약 설정 접근 차단', rpc('schedule_event_notification_cron', {}, actor)[0] == expected)
    for i in range(2):
        check('예약 설정 순차 재시도 ' + str(i + 1), rpc('schedule_event_notification_cron', {})[0] == 204 and len(jobs()) == 2)
    before = jobs()
    def invoke(barrier):
        with psycopg.connect(URL, password=PASSWORD, connect_timeout=20) as c:
            c.execute("set local statement_timeout='10s'")
            c.execute('set local role service_role')
            c.execute("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true)")
            barrier.wait(timeout=10)
            c.execute('select public.schedule_event_notification_cron()')
        return True
    for i in range(2):
        barrier = threading.Barrier(2)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(invoke, barrier) for _ in range(2)]
            check('동시 예약 설정 두 호출 모두 성공 ' + str(i + 1), all(f.result(timeout=25) for f in futures))
        now = jobs()
        check('동시 실행 후 작업 두 개와 실행 내용 보존 ' + str(i + 1), len(now) == 2 and [(x['name'], x['schedule'], x['command_hash']) for x in now] == [(x['name'], x['schedule'], x['command_hash']) for x in before])
    before = jobs()
    try:
        with CONNECTION.transaction():
            CONNECTION.execute('set local role service_role')
            CONNECTION.execute("select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true)")
            CONNECTION.execute('select public.schedule_event_notification_cron()')
            CONNECTION.execute('select 1/0')
    except psycopg.errors.DivisionByZero:
        pass
    check('설정 중 트랜잭션 오류는 기존 작업 원상복구', jobs() == before)
    secret_id = query("select id from vault.secrets where name='event_notification_cron_secret'")
    CONNECTION.execute("select vault.update_secret(%s,new_name:='hardening-temporarily-missing-secret')", (secret_id,))
    try:
        status, _ = rpc('schedule_event_notification_cron', {})
        check('필수 설정 누락은 기존 예약 작업 보존', status == 400 and jobs() == before)
    finally:
        CONNECTION.execute("select vault.update_secret(%s,new_name:='event_notification_cron_secret')", (secret_id,))
    check('실패 뒤 예약 재설정 복구', rpc('schedule_event_notification_cron', {})[0] == 204 and len(jobs()) == 2)


def pure_validator_tests():
    name = 'is_valid_operating_notice_daily_schedules'
    base = {'schedules': [], 'period_start': '2026-10-01', 'period_end': '2026-10-31'}
    day = {'date': '2026-10-10', 'closed': True, 'schedule_override': None}
    override = {'closed': False, 'open': '11:00', 'close': '22:00', 'close_next_day': False, 'break_times': []}
    cases = [('빈 배열', [], True), ('정상 휴업', [day], True), ('중복 날짜', [day, day], False),
             ('범위 밖', [{**day, 'date': '2026-11-01'}], False), ('불가능한 날짜', [{**day, 'date': '2026-10-32'}], False),
             ('날짜 누락', [{'closed': True}], False), ('closed 누락', [{'date': day['date']}], False),
             ('closed 잘못된 타입', [{**day, 'closed': 'true'}], False), ('객체 입력', {}, False), ('JSON null', None, False),
             ('32일 입력', [day] * 32, False), ('정상 변경 영업시간', [{**day, 'closed': False, 'schedule_override': override}], True),
             ('잘못된 시각', [{**day, 'closed': False, 'schedule_override': {**override, 'open': '25:00'}}], False),
             ('휴업과 영업시간 모순', [{**day, 'schedule_override': override}], False)]
    before = snapshot()
    for method in ['POST', 'GET']:
        for actor in ['anon', 'member', 'service']:
            status, body = rpc(name, {**base, 'schedules': [day]}, actor, method)
            check(method + ' ' + actor + ' 공개 순수 검증 정상 응답', status == 200 and body is True)
        status, _ = rpc(name, base, 'invalid', method)
        check(method + ' 잘못된 인증 토큰 거절', status == 401)
        for label, schedules, expected in cases:
            status, body = rpc(name, {**base, 'schedules': schedules}, 'anon', method)
            check(method + ' ' + label + ' 입력 계약', status == 200 and body is expected, http_status=status)
        for patch, label in [({'period_start': '2026-11-01'}, '뒤집힌 날짜'), ({'period_end': '2026-11-01'}, '월 경계 초과')]:
            status, body = rpc(name, {**base, 'schedules': [day], **patch}, 'anon', method)
            check(method + ' ' + label + ' 거절', status == 200 and body is False)
        status, _ = rpc(name, {**base, 'unexpected_argument': True}, 'anon', method)
        check(method + ' 미정의 인자 거절', status == 404)
        status, _ = rpc(name, {k: v for k, v in base.items() if k != 'schedules'}, 'anon', method)
        check(method + ' 필수 인자 생략 거절', status == 404)
    check('검증 RPC의 모든 입력과 인증 검사 뒤 데이터 불변', snapshot() == before)
    return ['rpc_' + method + '_' + name + '/' + group for method in ['post', 'get'] for group in ['BASE', 'AUTH', 'INPUT', 'ALTERNATE']]


def cleanup():
    if CREATED_VAULT:
        CONNECTION.execute("select cron.unschedule(jobid) from cron.job where jobname in('event-notification-day-before','event-notification-event-day')")
        CONNECTION.execute('delete from vault.secrets where id=any(%s::uuid[])', (CREATED_VAULT,))
    if IDS:
        CONNECTION.execute('delete from public.ramen_shops where id=any(%s::uuid[])', (IDS,))
    if USER:
        status, _ = call('/auth/v1/admin/users/' + USER, method='DELETE')
        check('합성 계정과 세션 정리', status == 200 and query('select count(*) from auth.users where id=%s', (USER,)) == 0 and query('select count(*) from auth.sessions where user_id=%s', (USER,)) == 0)
    STATE.unlink(missing_ok=True)


if __name__ == '__main__':
    baseline, failure, coverage = snapshot(), None, []
    try:
        setup()
        search_path_tests()
        menu_validation_tests()
        cascade_and_view_tests()
        cron_tests()
        coverage = pure_validator_tests()
    except BaseException as error:
        failure = {'type': type(error).__name__, 'message': str(error)[:180]}
    finally:
        try:
            cleanup()
            check('모든 fixture 제거 후 기존 집계와 내용 복원', snapshot() == baseline)
            check('임시 cron과 Vault 정리', not jobs() and query('select count(*) from vault.secrets where id=any(%s::uuid[])', (CREATED_VAULT,)) == 0)
        except BaseException as error:
            failure = {**(failure or {}), 'cleanup_error': type(error).__name__ + ': ' + str(error)[:180]}
        OUT.write_text(json.dumps({'project_ref': REF, 'cases': CASES, 'requests': REQUESTS, 'covered_unrun_checks': coverage,
            'login_requests': 1 if TOKEN else 0, 'failure': failure, 'baseline_restored': snapshot() == baseline,
            'production_mutations': 0, 'real_provider_calls': 0}, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({'cases': len(CASES), 'passed': sum(x['passed'] for x in CASES), 'http_requests': len(REQUESTS), 'covered_unrun_checks': len(coverage), 'failure': failure}, ensure_ascii=False))
        CONNECTION.close()
    if failure:
        raise SystemExit(1)
