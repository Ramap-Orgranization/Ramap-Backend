#!/usr/bin/env python3
"""격리 staging에서 푸시 등록 한도·형식·동시성·계정 전환을 검사하고 fixture를 복원한다."""
import argparse
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
    for name in ['config','db-url-file','db-password-file','project-ref','output']:
        parser.add_argument('--'+name,required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    url = Path(args.db_url_file).read_text().strip()
    assert args.project_ref=='gedptwzjortijxpjvmbc' and config['project_ref']==args.project_ref, '운영에서는 fixture 검사를 하지 않습니다'
    assert args.project_ref in url and config['url'].rstrip('/')==f'https://{args.project_ref}.supabase.co'
    connection = psycopg.connect(url,password=Path(args.db_password_file).read_text().strip(),autocommit=True,connect_timeout=20)
    accounts,cases = {},[]
    requests,request_lock = 0,threading.Lock()
    failure = None
    helper_created = False
    label = uuid.uuid4().hex

    def query(sql,values=()):
        return connection.execute(sql,values or None).fetchone()[0]

    def check(name,condition,**details):
        cases.append({'case':name,'passed':bool(condition),**details})
        if not condition:
            raise AssertionError(name)

    def call(method,path,body=None,actor='anon',headers=None):
        nonlocal requests
        key = config['service_role'] if actor=='service' else config['anon']
        token = key if actor in ['anon','service'] else accounts[actor]['token']
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(config['url'].rstrip('/')+path,data=data,headers={'apikey':key,'Authorization':'Bearer '+token,'Content-Type':'application/json',**(headers or {})},method=method)
        with request_lock:
            requests += 1
        try:
            response = urllib.request.urlopen(request,timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            payload = response.read()
            status,response_headers = response.status,response.headers
        return status,json.loads(payload) if payload else None,response_headers

    def fid():
        return 'c'+secrets.token_urlsafe(20)[:21]

    def token():
        return 'fcm:'+secrets.token_urlsafe(104)

    def register(identifier,actor='A',platform='android',target_type='fid',headers=None):
        return call('POST','/rest/v1/rpc/register_push_registration',{'registration_identifier':identifier,'device_platform':platform,'registration_target_type':target_type},actor,headers)

    def unregister(actor='A'):
        return call('POST','/rest/v1/rpc/unregister_push_registrations',{},actor)

    def success(reply):
        return reply[0] in [200,204]

    def retry_seconds(headers):
        return max([int(v.strip()) for v in headers.get('Retry-After','').split(',') if v.strip().isdigit()],default=0)

    def limited(reply):
        return reply[0]==429 and reply[1].get('code')=='PUSH_REGISTRATION_RATE_LIMITED' and retry_seconds(reply[2])>0

    def slot_limited(reply):
        return reply[0]==409 and reply[1].get('code')=='PUSH_DEVICE_LIMIT_REACHED'

    def snapshot():
        return query("""select jsonb_build_object(
        'settings',(select jsonb_build_object('maximum_registrations',maximum_registrations,'actor_minute_limit',actor_minute_limit,'actor_daily_limit',actor_daily_limit,'refresh_window_seconds',refresh_window_seconds,'enabled',enabled,'secret_digest',encode(extensions.digest(digest_secret,'sha256'),'hex')) from push_registration_private.settings),
        'counters',(select count(*) from push_registration_private.counters),'registrations',(select count(*) from public.push_registrations),
        'registration_digest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(p) order by p.identifier)::text,'[]'),'sha256'),'hex') from public.push_registrations p),
        'users',(select count(*) from auth.users),'profiles',(select count(*) from public.public_profiles))""")

    baseline = snapshot()
    assert baseline['counters']==0, '사용 중인 quota는 초기화하지 않습니다'
    assert query("select count(*) from vault.secrets where name like 'discord%' or name like '%webhook%'")==0
    assert query("select count(*) from pg_namespace where nspname='push_registration_test'")==0

    def clear():
        for account in accounts.values():
            connection.execute('delete from public.push_registrations where user_id=%s',(account['id'],))
        connection.execute('delete from push_registration_private.counters')
        connection.execute('update push_registration_private.settings set maximum_registrations=5,actor_minute_limit=1000,actor_daily_limit=1000,refresh_window_seconds=300,enabled=true')

    def state():
        return query("""select jsonb_build_object('rows',(select count(*) from public.push_registrations where user_id=any(%s::uuid[])),
        'units',(select coalesce(sum(consumed),0) from push_registration_private.counters where scope='day'),
        'max_account',(select coalesce(max(n),0) from (select count(*) n from public.push_registrations where user_id=any(%s::uuid[]) group by user_id)x))""",([x['id'] for x in accounts.values()],[x['id'] for x in accounts.values()]))

    try:
        for role in ['anon','authenticated']:
            for operation in ['select * from push_registration_private.settings','delete from push_registration_private.counters',"select push_registration_private.register_identifier('forged','android','fid')"]:
                denied=False
                try:
                    with connection.transaction(force_rollback=True):
                        connection.execute('set local role '+role)
                        connection.execute(operation)
                except psycopg.errors.InsufficientPrivilege:
                    denied=True
                check(role+'는 private 설정·counter·helper를 못 쓴다 '+str(len(cases)),denied)
        for operation in ['select digest_secret from push_registration_private.settings','update push_registration_private.settings set enabled=false','delete from push_registration_private.counters']:
            denied=False
            try:
                with connection.transaction(force_rollback=True):
                    connection.execute('set local role service_role')
                    connection.execute(operation)
            except psycopg.errors.InsufficientPrivilege:
                denied=True
            check('service_role도 비밀 조회·quota 변경을 못 한다 '+str(len(cases)),denied)
        for actor in ['A','B']:
            password=secrets.token_urlsafe(30)
            email=f'push.{label}.{actor}@example.invalid'
            status,user,_=call('POST','/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True,'user_metadata':{'role':'service_role'}},'service')
            check(actor+' 임시 계정 생성',status==200 and bool(user.get('id')))
            accounts[actor]={'id':user['id']}
            status,session,_=call('POST','/auth/v1/token?grant_type=password',{'email':email,'password':password})
            check(actor+'는 한번 로그인한 세션을 재사용한다',status==200 and bool(session.get('access_token')))
            accounts[actor]['token']=session['access_token']

        clear()
        identifier=fid()
        first=register(identifier)
        check('정상 Android FID 등록은void 성공이다',success(first),http_status=first[0],code=first[1].get('code') if isinstance(first[1],dict) else None)
        before=query('select updated_at::text from public.push_registrations where identifier=%s',(identifier,))
        replies=[register(identifier) for _ in range(16)]
        after=query('select updated_at::text from public.push_registrations where identifier=%s',(identifier,))
        check('같은 식별자16재전송은1행·1예산이며 바로timestamp를 바꾸지 않는다',all(success(r) for r in replies) and state()=={'rows':1,'units':1,'max_account':1} and before==after)
        connection.execute("update public.push_registrations set updated_at=now()-interval '1 hour' where identifier=%s",(identifier,))
        refresh=register(identifier)
        check('오래된 기존 등록의timestamp는갱신하고새 예산을 안 쓴다',success(refresh) and query('select updated_at>now()-interval \'1 minute\' from public.push_registrations where identifier=%s',(identifier,)) and state()['units']==1)
        check('정상 iOS FCM token 등록도 허용한다',success(register(token(),platform='ios',target_type='token')) and state()['rows']==2)
        check('기존 Android token·iOS fid 계약도 유지한다',success(register(token(),platform='android',target_type='token')) and success(register(fid(),platform='ios',target_type='fid')) and state()['rows']==4)

        clear()
        identifiers=[fid() for _ in range(5)]
        replies=[register(x) for x in identifiers]
        sixth=register(fid())
        check('계정당5개 뒤6번째는409로막힌다',all(success(r) for r in replies) and slot_limited(sixth) and state()=={'rows':5,'units':5,'max_account':5})
        check('가득찬계정도기존등록은갱신한다',success(register(identifiers[0])) and state()['units']==5)
        check('다른계정의5개한도는독립적이다',success(register(fid(),'B')) and state()['rows']==6 and state()['max_account']==5)

        clear()
        identifier=fid()
        register(identifier)
        transfer=register(identifier,'B')
        check('같은기기의계정전환은새소유자로이전하고한행이다',success(transfer) and query('select user_id=%s::uuid from public.push_registrations where identifier=%s',(accounts['B']['id'],identifier)) and state()=={'rows':1,'units':2,'max_account':1})
        check('예전계정로그아웃은이전된등록을삭제하지않는다',success(unregister('A')) and state()['rows']==1)
        register(fid(),'A')
        for _ in range(4): register(fid(),'B')
        source=query('select identifier from public.push_registrations where user_id=%s',(accounts['A']['id'],))
        rejected=register(source,'B')
        check('가득찬계정의추가이전은거절되고원래소유자를보존한다',slot_limited(rejected) and query('select user_id=%s::uuid from public.push_registrations where identifier=%s',(accounts['A']['id'],source)) and state()['rows']==6)

        clear()
        remaining=query('select 60-extract(second from clock_timestamp())')
        if remaining<10: time.sleep(float(remaining)+0.2)
        connection.execute('update push_registration_private.settings set actor_minute_limit=2')
        identifiers=[fid() for _ in range(3)]
        replies=[register(x) for x in identifiers]
        check('새등록분당한도를넘으면429이고두행만남는다',success(replies[0]) and success(replies[1]) and limited(replies[2]) and state()=={'rows':2,'units':2,'max_account':2})
        check('등록변경한도를소진해도동일기기재등록은허용한다',success(register(identifiers[0])) and state()['units']==2)
        metadata_change=register(identifiers[0],platform='ios')
        check('기존행의플랫폼변경도변경예산을쓰므로우회못한다',limited(metadata_change) and query('select platform from public.push_registrations where identifier=%s',(identifiers[0],))=='android')

        clear()
        connection.execute('update push_registration_private.settings set actor_daily_limit=2')
        identifiers=[fid() for _ in range(3)]
        replies=[register(x,headers={'x-user-id':str(uuid.uuid4()),'x-forwarded-for':f'203.0.113.{i}'}) for i,x in enumerate(identifiers)]
        check('metadata역할·IP·사용자ID헤더를바꿔도계정일한도를못피한다',success(replies[0]) and success(replies[1]) and limited(replies[2]))
        check('한국자정기준의하루창이다',query("select bool_and(extract(hour from window_start at time zone 'Asia/Seoul')=0 and extract(minute from window_start at time zone 'Asia/Seoul')=0) from push_registration_private.counters where scope='day'"))
        unregister()
        check('등록해제뒤재등록으로일예산을초기화하지못한다',limited(register(fid())) and state()=={'rows':0,'units':2,'max_account':0})
        check('다른회원은독립적인새등록예산이다',success(register(fid(),'B')) and state()['rows']==1)

        clear()
        connection.execute('update push_registration_private.settings set maximum_registrations=3')
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            replies=list(workers.map(lambda _:register(fid()),range(12)))
        check('동시12새등록과개수한도3은정확히3성공·9거절이다',sum(success(r) for r in replies)==3 and sum(slot_limited(r) for r in replies)==9 and state()=={'rows':3,'units':3,'max_account':3})
        clear()
        connection.execute('update push_registration_private.settings set actor_daily_limit=3')
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            replies=list(workers.map(lambda _:register(fid()),range(12)))
        check('동시12변경과일한도3도정확히3성공·9개429다',sum(success(r) for r in replies)==3 and sum(limited(r) for r in replies)==9 and state()=={'rows':3,'units':3,'max_account':3})
        clear()
        identifier=fid()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            replies=list(workers.map(lambda _:register(identifier),range(8)))
        check('동시같은기기8등록도한행·한예산이다',all(success(r) for r in replies) and state()=={'rows':1,'units':1,'max_account':1})
        clear()
        identifier=fid()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            replies=list(workers.map(lambda i:register(identifier,'A' if i%2==0 else 'B'),range(8)))
        check('두계정의동시같은기기등록은소유자한명·한행이다',all(success(r) for r in replies) and state()['rows']==1 and state()['max_account']==1)

        clear()
        bad=[(None,'android','fid'),('','android','fid'),('c'+'a'*20,'android','fid'),('c'+'a'*22,'android','fid'),('g'+'a'*21,'android','fid'),('c'+'a'*20+'/','android','fid'),(fid(),None,'fid'),(fid(),'web','fid'),(fid(),'android',None),(fid(),'android','apns'),('x'*19,'ios','token'),('x'*65536,'ios','token'),('valid-token-with space','ios','token'),('valid-token-newline\nabc','ios','token'),('한'*700,'ios','token')]
        for i,(identifier,platform,target_type) in enumerate(bad):
            reply=register(identifier,platform=platform,target_type=target_type)
            check('잘못된길이·형식·플랫폼·유형을400으로막는다 '+str(i),reply[0]==400 and reply[1].get('code')=='22023' and state()['rows']==0 and state()['units']==0)
        check('FCM token20자하한은허용한다',success(register('t'*20,platform='ios',target_type='token')))
        check('FCM token2048byte상한은허용한다',success(register('t'*2048,platform='ios',target_type='token')))
        too_long=register('t'*2049,platform='ios',target_type='token')
        check('FCM token2049byte는거절한다',too_long[0]==400 and state()['rows']==2)
        clear()
        for actor in ['anon','service']:
            reply=register(fid(),actor)
            check(actor+'의실제사용자ID없는등록은거절한다',reply[0] in [401,403] and state()['rows']==0)
        reply=call('POST','/rest/v1/push_registrations',{'identifier':fid(),'user_id':accounts['A']['id'],'platform':'android','target_type':'fid'},'A')
        check('직접테이블INSERT로보호함수를우회못한다',reply[0] in [401,403] and state()['rows']==0)

        connection.execute('update push_registration_private.settings set enabled=false')
        reply=register(fid())
        check('등록비활성은503으로닫히고쓰기를안한다',reply[0]==503 and reply[1].get('code')=='PUSH_REGISTRATION_UNAVAILABLE' and retry_seconds(reply[2])==30 and state()['rows']==0)
        clear()
        missing_closed=False
        try:
            with connection.transaction(force_rollback=True):
                connection.execute('delete from push_registration_private.settings')
                connection.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'role':'authenticated','sub':accounts['A']['id']}),))
                connection.execute('select public.register_push_registration(%s,%s,%s)',(fid(),'android','fid'))
        except psycopg.Error as error:
            missing_closed=error.sqlstate=='PGRST' and json.loads(error.diag.message_detail)['status']==503
        check('설정누락도503이며등록·quota를안만든다',missing_closed and state()['rows']==0 and state()['units']==0)

        connection.execute('create schema push_registration_test')
        helper_created=True
        connection.execute("""create function push_registration_test.fail_insert() returns trigger language plpgsql set search_path='' as $$begin raise exception '합성 등록 실패' using errcode='22023';end;$$""")
        connection.execute('create trigger zz_push_test_fail after insert on public.push_registrations for each row execute function push_registration_test.fail_insert()')
        reply=register(fid())
        check('INSERT뒤실패는등록과counter전체를롤백한다',reply[0]==400 and state()['rows']==0 and state()['units']==0)
        connection.execute('drop trigger zz_push_test_fail on public.push_registrations')
        connection.execute('drop schema push_registration_test cascade')
        helper_created=False
        clear()
        connection.execute('update push_registration_private.settings set actor_daily_limit=2')
        rolled_back=False
        try:
            with connection.transaction(force_rollback=True):
                connection.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'role':'authenticated','sub':accounts['A']['id']}),))
                for _ in range(3): connection.execute('select public.register_push_registration(%s,%s,%s)',(fid(),'android','fid'))
        except psycopg.Error as error:
            rolled_back=error.sqlstate=='PGRST' and json.loads(error.diag.message_detail)['status']==429
        check('한트랜잭션의등록한도초과도부분저장없다',rolled_back and state()['rows']==0 and state()['units']==0)
        clear()
        identifier=fid()
        register(identifier)
        text=query('select coalesce(jsonb_agg(to_jsonb(c)),\'[]\')::text from push_registration_private.counters c')
        check('quota에원문사용자ID·식별자·token이없다',identifier not in text and all(a['id'] not in text for a in accounts.values()))
    except BaseException as error:
        failure=type(error).__name__+': '+str(error)
    finally:
        if helper_created:
            connection.execute('drop trigger if exists zz_push_test_fail on public.push_registrations')
            connection.execute('drop schema push_registration_test cascade')
        clear()
        for account in accounts.values(): call('DELETE','/auth/v1/admin/users/'+account['id'],actor='service')
        settings=baseline['settings']
        connection.execute('update push_registration_private.settings set maximum_registrations=%s,actor_minute_limit=%s,actor_daily_limit=%s,refresh_window_seconds=%s,enabled=%s',(settings['maximum_registrations'],settings['actor_minute_limit'],settings['actor_daily_limit'],settings['refresh_window_seconds'],settings['enabled']))
        final=snapshot()
        connection.close()
    report={'cases':cases,'passed_cases':sum(c['passed'] for c in cases),'HTTP_requests':requests,'failure':failure,'baseline_restored':baseline==final,'baseline':baseline,'final':final,'actual_provider_calls':0,'actual_notifications':0,'production_requests':0,'test_accounts_created':len(accounts),'password_logins':2,'temporary_helper_removed':True}
    Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['passed_cases','HTTP_requests','failure','baseline_restored']},ensure_ascii=False))
    if failure or baseline!=final: raise SystemExit(1)


if __name__=='__main__':
    main()
