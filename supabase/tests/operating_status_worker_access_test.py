#!/usr/bin/env python3
"""실제 staging에서 워커 전용 권한과 기존 선점·동시 실행 계약을 검증한다."""
import argparse
import concurrent.futures
import json
import os
import secrets
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
import psycopg

REF='gedptwzjortijxpjvmbc'
RPC='/rest/v1/rpc/claim_due_shop_operating_statuses'
FIELDS={'id','name','naver_place_url','business_hours_weekly','business_hours_break_times',
        'check_interval_minutes','check_reason','consecutive_failures'}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,request,response,code,message,headers,newurl):return None

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase',choices=['before','after','cleanup'],required=True)
    for name in ['config','db-url-file','db-password-file','state','output']:
        parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    config=json.loads(Path(args.config).read_text())
    url=Path(args.db_url_file).read_text().strip()
    assert config['project_ref']==REF and REF in url, '운영에서는 상태 선점·fixture를 실행하지 않습니다'
    assert config['url'].rstrip('/')==f'https://{REF}.supabase.co'
    password=Path(args.db_password_file).read_text().strip()
    connection=psycopg.connect(url,password=password,autocommit=True,connect_timeout=20)
    connection.execute("set statement_timeout='10s'")
    state_path=Path(args.state)
    state={'project_ref':REF,'users':{},'shops':[],'before_cases':[],'before_requests':0} if args.phase=='before' else json.loads(state_path.read_text())
    assert state['project_ref']==REF
    cases=[];requests=0;failure=None;keep=False
    request_lock=threading.Lock()
    opener=urllib.request.build_opener(NoRedirect)

    def query(sql,params=()):return connection.execute(sql,params or None).fetchone()[0]
    def check(name,condition,**details):
        cases.append({'case':name,'passed':bool(condition),**details})
        assert condition,name
    def save_state():
        descriptor=os.open(state_path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(descriptor,'w') as output:json.dump(state,output)
        state_path.chmod(0o600)
    def call(method,path,body=None,actor='anon'):
        nonlocal requests
        with request_lock:requests+=1
        key=config['service_role'] if actor=='service' else config['anon']
        token=key if actor in ['service','anon'] else state['users'][actor]['token']
        req=urllib.request.Request(config['url'].rstrip('/')+path,method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'apikey':key,'Authorization':'Bearer '+token,'Content-Type':'application/json'})
        try:response=opener.open(req,timeout=20)
        except urllib.error.HTTPError as error:response=error
        with response:
            data=response.read()
            return response.status,json.loads(data) if data else None
    def claim(limit=None,actor='service',method='POST',omitted=False):
        body={} if omitted else {'batch_limit':limit}
        path=RPC+('' if method=='POST' else '?'+urllib.parse.urlencode(body))
        return call(method,path,body if method=='POST' else None,actor)
    def denied(reply):return reply[0] in [401,403] and isinstance(reply[1],dict) and reply[1].get('code')=='42501'
    def snapshot():
        return query("""select jsonb_build_object(
            'shops',(select jsonb_build_object('rows',count(*),'digest',encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(s) order by id)::text,'[]'),'sha256'),'hex')) from public.ramen_shops s),
            'statuses',(select jsonb_build_object('rows',count(*),'digest',encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(s) order by shop_id)::text,'[]'),'sha256'),'hex')) from public.shop_operating_status s),
            'auth_users',(select count(*) from auth.users),'profiles',(select count(*) from public.public_profiles),
            'storage',(select count(*) from storage.objects),'pushes',(select count(*) from public.push_registrations))""")
    def reset_due():
        connection.execute("update public.shop_operating_status set next_check_at=now()-interval '1 minute',check_reason='initial' where shop_id=any(%s::uuid[])",(state['shops'],))
    def cleanup():
        if state['shops']:
            connection.execute('delete from public.ramen_shops where id=any(%s::uuid[])',(state['shops'],))
        for user in state['users'].values():
            reply=call('DELETE','/auth/v1/admin/users/'+user['id'],actor='service')
            check('합성 계정과 세션을 제거한다',reply[0] in [200,404])
        final=snapshot()
        check('모든 fixture 제거 후 기존 집계·내용을 복원한다',final==state['baseline'])
        return final

    try:
        assert query('select count(*) from cron.job where active')==0
        assert query("select count(*) from pg_trigger t join pg_proc p on p.oid=t.tgfoid where t.tgrelid in ('public.ramen_shops'::regclass,'public.shop_operating_status'::regclass) and not t.tgisinternal and p.prosrc~*'(net.http|http_post|http_get|webhook|send_notification)'")==0
        if args.phase=='before':
            assert not state_path.exists(), '진행 중인 검사 상태를 덮어쓰지 않습니다'
            state['baseline']=snapshot();save_state()
            assert state['baseline']['shops']['rows']==state['baseline']['statuses']['rows']==0
            marker=uuid.uuid4().hex
            for actor in ['A','B']:
                email=f'worker.{marker}.{actor}@example.invalid';new_password=secrets.token_urlsafe(30)
                reply=call('POST','/auth/v1/admin/users',{'email':email,'password':new_password,'email_confirm':True,'user_metadata':{'role':'service_role','is_admin':True}},'service')
                check(actor+' 합성 계정을 생성한다',reply[0]==200 and bool(reply[1].get('id')))
                state['users'][actor]={'id':reply[1]['id']};save_state()
                reply=call('POST','/auth/v1/token?grant_type=password',{'email':email,'password':new_password})
                check(actor+'는 한번 로그인한 세션을 재사용한다',reply[0]==200 and bool(reply[1].get('access_token')))
                state['users'][actor]['token']=reply[1]['access_token'];save_state()
            for actor in ['anon','A','B']:
                reply=claim(1,actor)
                check(actor+' 수정 전 빈 큐의 내부 API 호출이 실행된다',reply[0]==200 and reply[1]==[],http_status=reply[0])
            check('빈 큐의 공개 호출은 업무 행을 만들지 않았다',query('select count(*) from public.shop_operating_status')==0)
            state['before_cases']=cases;state['before_requests']=requests;save_state();keep=True
        elif args.phase=='after':
            for actor in ['anon','A','B']:
                for method in ['POST','GET']:
                    for limit in [1,100]:
                        reply=claim(limit,actor,method)
                        check(actor+' '+method+' 빈 큐에서도 내부 API를 거절한다',denied(reply),http_status=reply[0])
            empty=claim(1)
            check('서버 역할의 빈 큐 응답은 기존대로 유지한다',empty[0]==200 and empty[1]==[])
            rows=[]
            for number in range(56):
                shop=str(uuid.uuid4());state['shops'].append(shop)
                rows.append((shop,'Synthetic worker '+str(number),'Synthetic only',f'https://map.naver.com/p/entry/place/{99000000+number}'))
            hidden=str(uuid.uuid4());missing=str(uuid.uuid4());state['shops']+=[hidden,missing];save_state()
            with connection.cursor() as cursor:
                cursor.executemany('insert into public.ramen_shops(id,name,address,lat,lng,naver_place_url,menu_snapshot_enabled) values (%s,%s,%s,37,127,%s,false)',rows)
            connection.execute("insert into public.ramen_shops(id,name,address,lat,lng,naver_place_url,is_visible,menu_snapshot_enabled) values (%s,'Synthetic hidden','Synthetic only',37,127,'https://map.naver.com/p/entry/place/99999999',false,false),(%s,'Synthetic missing URL','Synthetic only',37,127,null,true,false)",(hidden,missing))
            before=snapshot()
            for actor in ['anon','A','B']:
                reply=claim(50,actor)
                check(actor+' 실제 due 자료가 있어도 선점을 거절한다',denied(reply),http_status=reply[0])
            check('일반 호출 거절 뒤 대상 가게·상태는 그대로다',snapshot()==before)
            for limit,expected,omitted in [(None,10,True),(None,10,False),(0,1,False),(-50,1,False),(1000,50,False)]:
                if query('select count(*) from public.shop_operating_status'):
                    reset_due()
                reply=claim(limit,omitted=omitted)
                check('서버 한도 '+('기본값' if omitted else str(limit))+'는기존 안전 한도로 선점한다',reply[0]==200 and len(reply[1])==expected,http_status=reply[0])
                check('서버 응답의 기존8필드와 장소/가게 연결을 유지한다',all(set(row)==FIELDS and row['id'] in state['shops'][:56] and row['naver_place_url'].startswith('https://map.naver.com/') for row in reply[1]))
                claimed=[row['id'] for row in reply[1]]
                check('선점한 행은 running과60분뒤로 저장된다',query("select count(*) from public.shop_operating_status where shop_id=any(%s::uuid[]) and check_reason='running' and next_check_at>now()+interval '59 minutes' and next_check_at<=now()+interval '61 minutes'",(claimed,))==expected)
            check('숨김 가게와 장소 URL 없는 가게는 큐에 추가되지 않는다',query('select count(*) from public.shop_operating_status where shop_id=any(%s::uuid[])',([hidden,missing],))==0)
            reset_due()
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                replies=list(pool.map(lambda _:claim(3),range(8)))
            all_ids=[row['id'] for status,data in replies for row in data]
            check('서비스 동시8요청은각3개씩서로다른24행을 선점한다',all(status==200 and len(data)==3 for status,data in replies) and len(all_ids)==len(set(all_ids))==24)
            remainder=claim(1000);again=claim(1000)
            check('후속 요청은나머지32개만선점하고이미선점한56행은반복되지않는다',remainder[0]==200 and len(remainder[1])==32 and not set(all_ids)&{row['id'] for row in remainder[1]} and again==(200,[]))
            reset_due()
            with psycopg.connect(url,password=password,autocommit=True,connect_timeout=20) as lock_connection:
                lock_connection.execute("set statement_timeout='10s'")
                with lock_connection.transaction():
                    locked=lock_connection.execute('select shop_id from public.shop_operating_status order by shop_id for update limit 1').fetchone()[0]
                    reply=claim(1)
                    check('기존SKIP LOCKED는다른작업자가잠근행을건너뛴다',reply[0]==200 and len(reply[1])==1 and reply[1][0]['id']!=str(locked))
            status_before=snapshot()
            with connection.transaction():
                connection.execute('set local role service_role')
                connection.execute('select * from public.claim_due_shop_operating_statuses(2)').fetchall()
                raise psycopg.Rollback
            check('서비스 선점 transaction 취소는상태를복원한다',snapshot()==status_before)
            for actor in ['anon','authenticated']:
                with connection.transaction():
                    connection.execute('set local role '+actor)
                    try:
                        connection.execute('select * from public.claim_due_shop_operating_statuses(1)').fetchall()
                    except psycopg.errors.InsufficientPrivilege:
                        denied_sql=True
                    else:
                        denied_sql=False
                    check(actor+' SQL에서도함수실행권한이없다',denied_sql)
                    raise psycopg.Rollback
            check('서버 역할의 함수 실행 권한은 남아 있다',query("select has_function_privilege('service_role','public.claim_due_shop_operating_statuses(integer)','EXECUTE')"))
        else:
            check('중단된 fixture 정리를 실행한다',True)
    except Exception as error:
        failure=type(error).__name__+': '+str(error) if isinstance(error,AssertionError) else type(error).__name__
        keep=False
    finally:
        final=None
        if not keep and 'baseline' in state:
            try:
                final=cleanup();state_path.unlink(missing_ok=True)
            except Exception as error:
                failure=(failure+'; ' if failure else '')+'cleanup '+type(error).__name__;save_state()
        report={'phase':args.phase,'cases':cases,'passed_cases':sum(c['passed'] for c in cases),'HTTP_requests':requests,'failure':failure,
                'baseline':state.get('baseline'),'final':final,'baseline_restored':final==state.get('baseline') if final else False,
                'fixture_retained_for_migration':keep,'before_passed_cases':sum(c['passed'] for c in state['before_cases']),
                'before_HTTP_requests':state['before_requests'],'password_logins':2 if args.phase=='before' else 0,
                'actual_provider_calls':0,'actual_notifications':0,'production_requests':0}
        Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k not in ['cases','baseline','final']},ensure_ascii=False))
        connection.close()
    if failure:raise SystemExit(1)

if __name__=='__main__':main()
