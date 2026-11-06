#!/usr/bin/env python3
"""격리 staging에서 리뷰 재전송·작성 한도·사진·롤백을 검사하고 원래 상태로 복원한다."""
import argparse
import base64
import concurrent.futures
import json
import secrets
import threading
import time
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
    assert args.project_ref == 'gedptwzjortijxpjvmbc' and config['project_ref'] == args.project_ref, '운영 프로젝트 검사는 허용하지 않습니다'
    assert args.project_ref in database_url and config['url'].rstrip('/') == f'https://{args.project_ref}.supabase.co'
    connection = psycopg.connect(database_url, password=Path(args.db_password_file).read_text().strip(), autocommit=True, connect_timeout=20)
    accounts, photos, cases = {}, [], []
    shops = [str(uuid.uuid4()), str(uuid.uuid4())]
    fixture_label = uuid.uuid4().hex
    requests, request_lock = 0, threading.Lock()
    failure = None
    helper_created = False

    def query(sql, values=()):
        return connection.execute(sql, values or None).fetchone()[0]

    def check(name, condition, **details):
        cases.append({'case': name, 'passed': bool(condition), **details})
        if not condition:
            raise AssertionError(name)

    def call(method, path, body=None, actor='anon', headers=None, raw=None):
        nonlocal requests
        token = config['service_role'] if actor == 'service' else accounts.get(actor, {}).get('token', config['anon'])
        request_headers = {'apikey': config['service_role'] if actor == 'service' else config['anon'], 'Authorization': 'Bearer ' + token, 'Content-Type': 'image/png' if raw is not None else 'application/json', **(headers or {})}
        data = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        with request_lock:
            requests += 1
        request = urllib.request.Request(config['url'].rstrip('/') + path, data=data, headers=request_headers, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            payload = response.read()
            status, reply_headers = response.status, response.headers
        decoded = json.loads(payload) if payload else None
        return status, decoded, reply_headers

    def rpc(name, body, actor='A', headers=None):
        return call('POST', '/rest/v1/rpc/' + name, body, actor, headers)

    def submit(body='synthetic review', actor='A', v2=False, value=None, headers=None):
        return rpc('submit_shop_review_v2' if v2 else 'submit_shop_review', value if value is not None else {'p_shop_id': shops[0], 'p_body': body}, actor, headers)

    def review_id(reply):
        return reply[1].get('review_id') if isinstance(reply[1], dict) else reply[1]

    def retry_seconds(headers):
        return max([int(v.strip()) for v in headers.get('Retry-After', '').split(',') if v.strip().isdigit()], default=0)

    def limited(reply):
        return reply[0] == 429 and reply[1].get('code') == 'REVIEW_RATE_LIMITED' and retry_seconds(reply[2]) > 0

    def snapshot():
        return query("""select jsonb_build_object(
            'settings',(select jsonb_build_object('actor_minute_limit',actor_minute_limit,'actor_daily_limit',actor_daily_limit,'replay_window_seconds',replay_window_seconds,'enabled',enabled,'secret_digest',encode(extensions.digest(digest_secret,'sha256'),'hex')) from review_submission_private.settings),
            'counters',(select count(*) from review_submission_private.counters),'receipts',(select count(*) from review_submission_private.receipts),
            'users',(select count(*) from auth.users),'profiles',(select count(*) from public.public_profiles),
            'shops',(select count(*) from public.ramen_shops),'reviews',(select count(*) from public.shop_reviews),
            'visits',(select count(*) from community_private.review_visit_counters),'objects',(select count(*) from storage.objects))""")

    baseline = snapshot()
    assert baseline['counters'] == 0 and baseline['receipts'] == 0, '사용 중인 staging quota는 초기화하지 않습니다'
    assert query("select count(*) from vault.secrets where name like 'discord%' or name like '%webhook%'") == 0, '실제 알림 설정이 없는 staging이 필요합니다'
    assert query("select count(*) from pg_namespace where nspname='review_submission_test'") == 0

    def clear():
        for account in accounts.values():
            connection.execute('delete from public.shop_reviews where user_id=%s', (account['id'],))
            connection.execute('delete from community_private.review_visit_counters where user_id=%s', (account['id'],))
        connection.execute('delete from review_submission_private.counters')
        connection.execute('delete from review_submission_private.receipts')
        connection.execute('update review_submission_private.settings set actor_minute_limit=1000,actor_daily_limit=1000,replay_window_seconds=600,enabled=true')

    def state():
        ids = [a['id'] for a in accounts.values()]
        return query("""select jsonb_build_object('rows',(select count(*) from public.shop_reviews where user_id=any(%s::uuid[])),
        'day_units',(select coalesce(sum(consumed),0) from review_submission_private.counters where scope='day'),
        'receipts',(select count(*) from review_submission_private.receipts),
        'visits',(select coalesce(sum(last_visit_number),0) from community_private.review_visit_counters where user_id=any(%s::uuid[])))""", (ids, ids))

    try:
        for role in ['anon', 'authenticated']:
            for operation in ['select * from review_submission_private.settings', 'delete from review_submission_private.counters', 'select * from review_submission_private.receipts', "select review_submission_private.reserve_submission('forged')", "select review_submission_private.remember_submission('forged',null)"]:
                denied = False
                try:
                    with connection.transaction(force_rollback=True):
                        connection.execute('set local role ' + role)
                        connection.execute(operation)
                except psycopg.errors.InsufficientPrivilege:
                    denied = True
                check(role + '는 private 상태 조회·초기화·helper 실행을 못 한다 ' + str(len(cases)), denied)
        for operation in ['select digest_secret from review_submission_private.settings', 'update review_submission_private.settings set enabled=false', 'delete from review_submission_private.counters']:
            denied = False
            try:
                with connection.transaction(force_rollback=True):
                    connection.execute('set local role service_role')
                    connection.execute(operation)
            except psycopg.errors.InsufficientPrivilege:
                denied = True
            check('service_role는 서명 비밀 조회·quota 변경을 못 한다 ' + str(len(cases)), denied)

        for actor in ['A', 'B']:
            password = secrets.token_urlsafe(30)
            email = f'review.{fixture_label}.{actor}@example.invalid'
            status, user, _ = call('POST', '/auth/v1/admin/users', {'email': email, 'password': password, 'email_confirm': True, 'user_metadata': {'role': 'service_role'}}, 'service')
            check(actor + ' 임시 계정 생성', status == 200 and bool(user.get('id')))
            accounts[actor] = {'id': user['id']}
            status, session, _ = call('POST', '/auth/v1/token?grant_type=password', {'email': email, 'password': password})
            check(actor + '는 한 번 로그인한 세션을 재사용한다', status == 200 and bool(session.get('access_token')))
            accounts[actor]['token'] = session['access_token']
        for shop in shops:
            connection.execute('insert into public.ramen_shops(id,name,address,lat,lng) values (%s,%s,%s,37,127)', (shop, 'Synthetic review shop', 'Synthetic only'))

        clear()
        first = submit()
        replies = [submit(v2=(index % 2 == 0)) for index in range(16)]
        check('구형·v2 재전송16회는 같은 리뷰ID를 반환한다', first[0] == 200 and all(r[0] == 200 and review_id(r) == review_id(first) for r in replies))
        check('리뷰·방문횟수·예산·receipt가 모두 한 건이다', state() == {'rows': 1, 'day_units': 1, 'receipts': 1, 'visits': 1})
        check('v2 재전송의 after·owner_counts도 한 건이다', replies[0][1]['after']['id'] == review_id(first) and replies[0][1]['owner_counts']['total_count'] == 1)
        check('기본 재전송 기간은10분이다', query('select bool_and(extract(epoch from expires_at-clock_timestamp()) between 570 and 600) from review_submission_private.receipts'))
        second = submit(actor='B')
        check('다른 계정의 같은 내용은 별도 리뷰다', second[0] == 200 and review_id(second) != review_id(first) and state()['rows'] == 2)
        other_shop = submit(value={'p_shop_id': shops[1], 'p_body': 'synthetic review'})
        private_review = submit(value={'p_shop_id': shops[0], 'p_body': 'synthetic review', 'p_is_public': False})
        check('다른 매장·공개 설정의 요청은 합치지 않는다', other_shop[0] == 200 and private_review[0] == 200 and state()['rows'] == 4)

        clear()
        remaining = query("select 60-extract(second from clock_timestamp())")
        if remaining < 10:
            time.sleep(float(remaining) + 0.2)
        connection.execute('update review_submission_private.settings set actor_minute_limit=2')
        replies = [submit('minute review ' + str(i), v2=(i % 2 == 0)) for i in range(3)]
        check('두 API가 같은 계정 분당 한도를 공유한다', replies[0][0] == 200 and replies[1][0] == 200 and limited(replies[2]), last_http_status=replies[2][0])
        duplicate = submit('minute review 0')
        check('한도 소진 후에도 기존 요청 재전송은 새 예산을 쓰지 않는다', duplicate[0] == 200 and review_id(duplicate) == review_id(replies[0]) and state()['day_units'] == 2)
        check('거절된 요청은 리뷰·방문횟수·receipt를 늘리지 않는다', state() == {'rows': 2, 'day_units': 2, 'receipts': 2, 'visits': 2})

        clear()
        connection.execute('update review_submission_private.settings set actor_daily_limit=2')
        replies = [submit('daily review ' + str(i), v2=(i % 2 == 0), headers={'x-user-id': str(uuid.uuid4()), 'x-forwarded-for': f'203.0.113.{i}'}) for i in range(3)]
        check('IP·metadata 역할을 바꿔도 계정 일 한도를 우회하지 못한다', replies[0][0] == 200 and replies[1][0] == 200 and limited(replies[2]))
        check('다른 계정은 독립적인 한도를 쓴다', submit('independent account', 'B', True)[0] == 200 and state()['rows'] == 3)
        check('하루 창은 한국 시각 자정이다', query("select bool_and(extract(hour from window_start at time zone 'Asia/Seoul')=0 and extract(minute from window_start at time zone 'Asia/Seoul')=0) from review_submission_private.counters where scope='day'"))
        before_delete = state()['day_units']
        reply = rpc('delete_shop_review', {'p_review_id': review_id(replies[0])})
        denied = submit('review after delete')
        check('리뷰 삭제로 작성 예산을 초기화하지 못한다', reply[0] in [200, 204] and limited(denied) and state()['day_units'] == before_delete)

        clear()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            replies = list(workers.map(lambda i: submit('parallel same review', v2=(i % 2 == 0)), range(8)))
        check('동시 중복8건은 같은 리뷰 한 건이다', all(r[0] == 200 for r in replies) and len({review_id(r) for r in replies}) == 1 and state() == {'rows': 1, 'day_units': 1, 'receipts': 1, 'visits': 1})
        clear()
        connection.execute('update review_submission_private.settings set actor_daily_limit=3')
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            replies = list(workers.map(lambda i: submit('parallel distinct ' + str(i), v2=(i % 2 == 0)), range(12)))
        check('동시 다른 요청12건과 한도3은 정확히3건만 허용한다', sum(r[0] == 200 for r in replies) == 3 and sum(limited(r) for r in replies) == 9 and state() == {'rows': 3, 'day_units': 3, 'receipts': 3, 'visits': 3})

        clear()
        connection.execute('update review_submission_private.settings set enabled=false')
        for v2 in [False, True]:
            reply = submit('disabled review', v2=v2)
            check(('v2' if v2 else '구형') + ' 제출 중단은503으로 닫힌다', reply[0] == 503 and reply[1].get('code') == 'REVIEW_SUBMISSION_UNAVAILABLE' and retry_seconds(reply[2]) == 30 and state()['rows'] == 0)
        clear()
        missing_closed = False
        try:
            with connection.transaction(force_rollback=True):
                connection.execute('delete from review_submission_private.settings')
                connection.execute("select set_config('request.jwt.claims',%s,true)", (json.dumps({'role': 'authenticated', 'sub': accounts['A']['id']}),))
                connection.execute('select public.submit_shop_review(%s,%s)', (shops[0], 'missing settings review'))
        except psycopg.Error as error:
            missing_closed = error.sqlstate == 'PGRST' and json.loads(error.diag.message_detail)['status'] == 503
        check('설정 누락도503이며 부분 저장이 없다', missing_closed and state()['rows'] == 0 and state()['day_units'] == 0)

        clear()
        bad_values = [{'p_shop_id': shops[0], 'p_body': 'x'}, {'p_shop_id': shops[0], 'p_body': 'x'*31}, {'p_shop_id': None, 'p_body': 'valid body'}, {'p_shop_id': shops[0], 'p_body': ' valid body '}, {'p_shop_id': str(uuid.uuid4()), 'p_body': 'valid body'}, {'p_shop_id': shops[0], 'p_body': 'valid body', 'p_image_paths': None}, {'p_shop_id': shops[0], 'p_body': 'valid body', 'p_is_public': None}]
        for index, value in enumerate(bad_values):
            reply = submit(value=value, v2=(index % 2 == 0))
            check('기존 입력 오류를 거절하며 예산을 쓰지 않는다 ' + str(index), reply[0] == 400 and state()['rows'] == 0 and state()['day_units'] == 0)
        for actor in ['anon', 'service']:
            reply = submit(actor=actor)
            check(actor + '에 실제 사용자ID가 없으면 작성할 수 없다', reply[0] in [401, 403] and state()['rows'] == 0)
        reply = call('POST', '/rest/v1/shop_reviews', {'shop_id': shops[0], 'user_id': accounts['A']['id'], 'body': 'direct bypass review'}, 'A')
        check('직접 테이블 INSERT로 한도를 우회할 수 없다', reply[0] in [401, 403] and state()['rows'] == 0)

        connection.execute('create schema review_submission_test')
        helper_created = True
        connection.execute("""create function review_submission_test.fail_insert() returns trigger language plpgsql set search_path='' as $$begin raise exception '합성 저장 실패' using errcode='22023';end;$$""")
        connection.execute('create trigger zz_review_test_fail after insert on public.shop_reviews for each row execute function review_submission_test.fail_insert()')
        reply = submit('rollback failure review')
        check('INSERT 이후 실패도 리뷰·방문횟수·quota·receipt 전체를 롤백한다', reply[0] == 400 and state() == {'rows': 0, 'day_units': 0, 'receipts': 0, 'visits': 0})
        connection.execute('drop trigger zz_review_test_fail on public.shop_reviews')
        connection.execute('drop schema review_submission_test cascade')
        helper_created = False

        clear()
        connection.execute('update review_submission_private.settings set actor_daily_limit=2')
        bulk_rolled_back = False
        try:
            with connection.transaction(force_rollback=True):
                connection.execute("select set_config('request.jwt.claims',%s,true)", (json.dumps({'role':'authenticated','sub':accounts['A']['id']}),))
                connection.execute("select public.submit_shop_review(%s,body) from unnest(array['bulk review first','bulk review second','bulk review third']) body", (shops[0],))
        except psycopg.Error as error:
            bulk_rolled_back = error.sqlstate == 'PGRST' and json.loads(error.diag.message_detail)['status'] == 429
        check('한 트랜잭션의 한도 초과도 전체 롤백한다', bulk_rolled_back and state() == {'rows': 0, 'day_units': 0, 'receipts': 0, 'visits': 0})

        clear()
        connection.execute('update review_submission_private.settings set replay_window_seconds=1')
        first = submit('later visit review')
        time.sleep(1.2)
        later = submit('later visit review')
        check('재전송 창 이후 같은 내용의 새 방문 리뷰를 허용한다', first[0] == 200 and later[0] == 200 and review_id(first) != review_id(later) and state()['rows'] == 2 and state()['visits'] == 2)
        clear()
        first = submit('original review body')
        reply = rpc('update_shop_review', {'p_review_id': review_id(first), 'p_body': 'updated review body', 'p_image_paths': [], 'p_is_public': True})
        replay = submit('original review body', v2=True)
        check('재전송이 수정된 리뷰를 다시 만들거나 되돌리지 않는다', reply[0] in [200,204] and replay[0] == 200 and review_id(replay) == review_id(first) and replay[1]['after']['body'] == 'updated review body' and state()['rows'] == 1)

        clear()
        photo = accounts['A']['id'] + '/' + str(uuid.uuid4()) + '.png'
        photos.append(photo)
        image = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE1cAAAAASUVORK5CYII=')
        reply = call('POST', '/storage/v1/object/shop-review-images/' + photo, actor='A', raw=image)
        check('사진fixture를 한 번 업로드한다', reply[0] == 200)
        value = {'p_shop_id': shops[0], 'p_body': 'photo review body', 'p_image_paths': [photo]}
        first = submit(value=value)
        replay = submit(value=value, v2=True)
        check('사진 리뷰의 같은 인자 재전송도 같은ID를 반환한다', first[0] == 200 and replay[0] == 200 and review_id(first) == review_id(replay) and state()['rows'] == 1)
        other = submit(value={**value, 'p_body':'different photo review'})
        unauthorized = submit(actor='B', value=value)
        check('사진 재사용·다른 계정 사진 권한 검사를 유지한다', other[0] == 400 and unauthorized[0] == 400 and state()['rows'] == 1 and state()['day_units'] == 1)
        check('제출 사진을 보존한다', query('select count(*) from storage.objects where bucket_id=%s and name=%s', ('shop-review-images',photo)) == 1)
        text = query("select jsonb_build_object('counters',(select jsonb_agg(to_jsonb(c)) from review_submission_private.counters c),'receipts',(select jsonb_agg(to_jsonb(r)) from review_submission_private.receipts r))::text")
        check('quota에는 원문 사용자ID·사진경로·리뷰본문이 없다', all(a['id'] not in text for a in accounts.values()) and photo not in text and 'photo review body' not in text)
    except BaseException as error:
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        if helper_created:
            connection.execute('drop trigger if exists zz_review_test_fail on public.shop_reviews')
            connection.execute('drop schema review_submission_test cascade')
        clear()
        for photo in photos:
            call('DELETE','/storage/v1/object/shop-review-images',{'prefixes':[photo]},'service')
        for account in accounts.values():
            call('DELETE','/auth/v1/admin/users/'+account['id'],actor='service')
        for shop in shops:
            connection.execute('delete from public.ramen_shops where id=%s',(shop,))
        settings = baseline['settings']
        connection.execute('update review_submission_private.settings set actor_minute_limit=%s,actor_daily_limit=%s,replay_window_seconds=%s,enabled=%s', (settings['actor_minute_limit'],settings['actor_daily_limit'],settings['replay_window_seconds'],settings['enabled']))
        final = snapshot()
        connection.close()
    report = {'cases':cases,'passed_cases':sum(c['passed'] for c in cases),'HTTP_requests':requests,'failure':failure,'baseline_restored':baseline==final,'baseline':baseline,'final':final,'actual_provider_calls':0,'actual_notifications':0,'production_requests':0,'temporary_helper_removed':True,'test_accounts_created':len(accounts),'password_logins':2}
    Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['passed_cases','HTTP_requests','failure','baseline_restored']},ensure_ascii=False))
    if failure or baseline!=final:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
