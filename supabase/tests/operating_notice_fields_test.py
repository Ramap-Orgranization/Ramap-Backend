#!/usr/bin/env python3
"""격리 staging에서 공지 내부 필드 비공개·기존 앱 조회·관리자 유지보수를 확인한다."""
import argparse
import json
import secrets
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import psycopg

PUBLIC = ['id','shop_id','notice_type','description','notice_date','start_time','end_time','source_url','created_at','updated_at','end_date','schedule_override','manually_released_at','daily_schedules']
INTERNAL = ['raw_post_id','ocr_text','confidence','review_note']

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,request,response,code,message,headers,newurl):
        return None

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['config','accounts','db-url-file','db-password-file','project-ref','output']:
        parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    config=json.loads(Path(args.config).read_text())
    dburl=Path(args.db_url_file).read_text().strip()
    assert args.project_ref=='gedptwzjortijxpjvmbc' and config['project_ref']==args.project_ref, '운영에는 fixture를 만들지 않습니다'
    assert args.project_ref in dburl and config['url'].rstrip('/')==f'https://{args.project_ref}.supabase.co'
    connection=psycopg.connect(dburl,password=Path(args.db_password_file).read_text().strip(),autocommit=True,connect_timeout=20)
    connection.execute("set statement_timeout='10s'")
    opener=urllib.request.build_opener(NoRedirect)
    accounts,cases,shops={},[],[]
    requests=0
    logins=0
    failure=None
    marker=uuid.uuid4().hex

    def query(sql,values=()):
        return connection.execute(sql,values or None).fetchone()[0]

    def check(name,condition,**details):
        cases.append({'case':name,'passed':bool(condition),**details})
        if not condition:
            raise AssertionError(name)

    def call(method,path,body=None,actor='anon',headers=None):
        nonlocal requests
        key=config['service_role'] if actor=='service' else config['anon']
        token=key if actor in ['service','anon'] else accounts[actor]['token']
        request=urllib.request.Request(config['url'].rstrip('/')+path,method=method,data=json.dumps(body).encode() if body is not None else None,
            headers={'apikey':key,'Authorization':'Bearer '+token,'Content-Type':'application/json',**(headers or {})})
        requests+=1
        try:
            response=opener.open(request,timeout=20)
        except urllib.error.HTTPError as error:
            response=error
        with response:
            payload=response.read()
            return response.status,json.loads(payload) if payload else None

    def denied(reply):
        return reply[0] in [401,403] and isinstance(reply[1],dict) and reply[1].get('code')=='42501'

    def snapshot():
        return query("""select jsonb_build_object(
            'notices',(select count(*) from operating_notice_private.shop_operating_notices),
            'notice_digest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(n) order by id)::text,'[]'),'sha256'),'hex') from operating_notice_private.shop_operating_notices n),
            'shops',(select count(*) from public.ramen_shops),
            'shop_digest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(s) order by id)::text,'[]'),'sha256'),'hex') from public.ramen_shops s),
            'raw_posts',(select count(*) from public.instagram_posts_raw),
            'raw_digest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(r) order by id)::text,'[]'),'sha256'),'hex') from public.instagram_posts_raw r),
            'profiles',(select count(*) from public.public_profiles),
            'profile_digest',(select encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(p) order by user_id)::text,'[]'),'sha256'),'hex') from public.public_profiles p),
            'users',(select count(*) from auth.users),
            'pushes',(select count(*) from public.push_registrations),
            'storage',(select count(*) from storage.objects))""")

    baseline=snapshot()
    assert query("select count(*) from cron.job where active")==0, '외부 호출이 없는 staging에서만 검사합니다'
    assert query("select count(*) from vault.secrets where name like 'discord%' or name like '%webhook%'")==0
    assert query("select count(*) from pg_trigger where tgrelid in ('operating_notice_private.shop_operating_notices'::regclass,'public.instagram_posts_raw'::regclass) and not tgisinternal")==0

    try:
        for actor in ['A','B']:
            password=secrets.token_urlsafe(30)
            email=f'notice.{marker}.{actor}@example.invalid'
            reply=call('POST','/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True,'user_metadata':{'role':'service_role','is_admin':True}},'service')
            check(actor+' 합성 계정 생성',reply[0]==200 and bool(reply[1].get('id')))
            accounts[actor]={'id':reply[1]['id']}
            reply=call('POST','/auth/v1/token?grant_type=password',{'email':email,'password':password})
            logins+=1
            check(actor+'는 한번 로그인한 세션을 재사용한다',reply[0]==200 and bool(reply[1].get('access_token')))
            accounts[actor]['token']=reply[1]['access_token']

        existing=json.loads(Path(args.accounts).read_text())
        assert existing['project_ref']==args.project_ref
        for user in existing['users']:
            reply=call('POST','/auth/v1/token?grant_type=password',{'email':user['email'],'password':user['password']})
            logins+=1
            check('기존 합성 관리자를 확인하는 로그인',reply[0]==200 and bool(reply[1].get('access_token')))
            accounts['admin']={'id':user['id'],'token':reply[1]['access_token']}
            probe=call('POST','/functions/v1/register-event',{'registration_type':'synthetic-invalid-type'},'admin')
            if probe[0]==400:
                break
        check('실제 관리자 검증을 통과하는 기존 합성 계정을 사용한다',probe[0]==400)

        shop=str(uuid.uuid4()); raw=str(uuid.uuid4()); notice=str(uuid.uuid4())
        shops.append(shop)
        shop_name='Synthetic notice '+marker
        connection.execute('insert into public.ramen_shops(id,name,address,lat,lng,menu_snapshot_enabled) values (%s,%s,%s,37,127,false)',(shop,shop_name,'Synthetic only'))
        connection.execute('insert into public.instagram_posts_raw(id,shop_id,instagram_username,source_type,source_url,source_key) values (%s,%s,%s,%s,%s,%s)',(raw,shop,'synthetic','post',f'https://example.invalid/{marker}',marker))
        body={'id':notice,'shop_id':shop,'raw_post_id':raw,'notice_type':'full_close','description':'Synthetic public notice','notice_date':'2099-10-01','end_date':'2099-10-02','source_url':f'https://example.invalid/{marker}','ocr_text':'SYNTHETIC PRIVATE OCR','review_note':'SYNTHETIC PRIVATE REVIEW','confidence':0.9}
        reply=call('POST','/rest/v1/admin_shop_operating_notice_records',body,'service',{'Prefer':'return=representation'})
        check('service 전용 경로는 내부 자료를 포함한 공지를 저장한다',reply[0]==201 and reply[1][0]['ocr_text']==body['ocr_text'] and reply[1][0]['review_note']==body['review_note'],http_status=reply[0],code=reply[1].get('code') if isinstance(reply[1],dict) else None)
        private_before=query('select to_jsonb(n) from operating_notice_private.shop_operating_notices n where id=%s',(notice,))

        for actor in ['anon','A','B','service','admin']:
            reply=call('GET',f'/rest/v1/shop_operating_notices?id=eq.{notice}&select=*',actor=actor)
            check(actor+'의 기존 wildcard 공지 조회는14개 공개 필드만 반환한다',reply[0]==200 and len(reply[1])==1 and set(reply[1][0])==set(PUBLIC) and reply[1][0]['description']==body['description'] and reply[1][0]['daily_schedules']==[])
        app_filter=urllib.parse.urlencode({'shop_id':'eq.'+shop,'or':'(end_date.is.null,end_date.gte.2099-10-01)'})
        reply=call('GET','/rest/v1/shop_operating_notices?'+app_filter)
        check('기존 앱의 매장·기간 필터를 유지한다',reply[0]==200 and reply[1][0]['id']==notice)
        for field in INTERNAL:
            reply=call('GET',f'/rest/v1/shop_operating_notices?id=eq.{notice}&select={field}')
            check(field+'를 직접 지정해도 공개 응답에서 읽지 못한다',reply[0]==400)
        for actor in ['anon','A','B']:
            reply=call('GET','/rest/v1/shop_operating_notices',actor=actor,headers={'Accept-Profile':'operating_notice_private'})
            check(actor+'는 원본 private schema를 HTTP로 열지 못한다',reply[0]==406 and reply[1].get('code')=='PGRST106')
            for method in ['GET','POST','PATCH','DELETE']:
                value=body if method=='POST' else {'description':'unauthorized'} if method=='PATCH' else None
                reply=call(method,f'/rest/v1/admin_shop_operating_notice_records?id=eq.{notice}',value,actor)
                check(actor+'의 관리자 원본 '+method+'는 권한으로 거절한다',denied(reply),http_status=reply[0],code=reply[1].get('code') if isinstance(reply[1],dict) else None)
            check(actor+'의 거절 요청은 원본 공지를 바꾸지 않았다',query('select to_jsonb(n) from operating_notice_private.shop_operating_notices n where id=%s',(notice,))==private_before)
        for actor in ['anon','A','B','service']:
            for method in ['POST','PATCH','DELETE']:
                value={k:v for k,v in body.items() if k in PUBLIC} if method=='POST' else {'description':'unauthorized'} if method=='PATCH' else None
                reply=call(method,f'/rest/v1/shop_operating_notices?id=eq.{notice}',value,actor)
                check(actor+'의 공개 공지 '+method+'는 읽기 전용 경로에서 거절한다',denied(reply),http_status=reply[0])
        check('모든 공개 쓰기 거절 뒤 원본이 그대로다',query('select to_jsonb(n) from operating_notice_private.shop_operating_notices n where id=%s',(notice,))==private_before)

        for actor in ['anon','A','B','service']:
            for name in ['fetch_shop_detail','fetch_shop_detail_v2']:
                for method in ['GET','POST']:
                    path='/rest/v1/rpc/'+name+(('?p_shop_id='+shop) if method=='GET' else '')
                    reply=call(method,path,{'p_shop_id':shop} if method=='POST' else None,actor)
                    check(actor+' '+name+' '+method+' 상세 JSON도 내부 필드를 포함하지 않는다',reply[0]==200 and len(reply[1])==1 and set(reply[1][0]['operating_notice'])==set(PUBLIC) and reply[1][0]['operating_notice']['id']==notice)
        reply=call('GET',f'/rest/v1/admin_shop_operating_notice_records?id=eq.{notice}&select=*,ramen_shops(name)',actor='service')
        check('관리자 원본 경로는 FK 매장 관계를 유지한다',reply[0]==200 and reply[1][0]['ramen_shops']['name']==shop_name)
        reply=call('GET',f'/rest/v1/shop_operating_notices?id=eq.{notice}&select=*,ramen_shops(name)')
        check('공개 공지 뷰도 FK 매장 관계를 유지한다',reply[0]==200 and reply[1][0]['ramen_shops']['name']==shop_name and not any(k in reply[1][0] for k in INTERNAL))

        for role in ['anon','authenticated']:
            for field in ['ocr_text','review_note','confidence','raw_post_id']:
                check(role+'의 원본 '+field+' 열 권한은 없다',not query("select has_column_privilege(%s,'operating_notice_private.shop_operating_notices',%s,'SELECT')",(role,field)))
            denied_sql=False
            try:
                with connection.transaction(force_rollback=True):
                    connection.execute('set local role '+role)
                    connection.execute('select ocr_text,review_note from operating_notice_private.shop_operating_notices')
            except psycopg.errors.InsufficientPrivilege:
                denied_sql=True
            check(role+'는 schema 이름을 알아도 원본 SQL 조회를 못 한다',denied_sql)
        with connection.transaction(force_rollback=True):
            connection.execute("alter table operating_notice_private.shop_operating_notices add column synthetic_future_internal text default 'PRIVATE FUTURE'")
            connection.execute('set local role anon')
            public_row=query('select to_jsonb(n) from public.shop_operating_notices n where id=%s',(notice,))
            check('원본에 새 내부 열이 생겨도 공개 wildcard에 자동 추가되지 않는다',set(public_row)==set(PUBLIC))
        check('추가 열 fixture는 transaction rollback으로 정리됐다',query("select count(*) from information_schema.columns where table_schema='operating_notice_private' and column_name='synthetic_future_internal'")==0)

        reply=call('PATCH',f'/rest/v1/admin_shop_operating_notice_records?id=eq.{notice}',{'description':'Synthetic updated public','ocr_text':'SYNTHETIC UPDATED OCR','review_note':None},'service',{'Prefer':'return=representation'})
        check('service는 공개 내용·OCR 수정과 검토 메모 null 초기화를 보존한다',reply[0]==200 and reply[1][0]['ocr_text']=='SYNTHETIC UPDATED OCR' and reply[1][0]['review_note'] is None)
        reply=call('GET',f'/rest/v1/shop_operating_notices?id=eq.{notice}')
        check('관리자 수정 후에도 공개 내용만 보이고 내부 자료는 감춘다',reply[0]==200 and reply[1][0]['description']=='Synthetic updated public' and set(reply[1][0])==set(PUBLIC))
        for actor in ['A','B']:
            reply=call('POST','/functions/v1/admin-correct-registration',{'action':'apply','registration_type':'operating_notice','target_id':notice,'changes':{'description':'unauthorized'}},actor)
            check(actor+'의 metadata 관리자 위조는 실제 수정 Edge에서 거절한다',reply[0]==403 and reply[1].get('code')=='administrator_required')
        reply=call('POST','/functions/v1/admin-correct-registration',{'action':'apply','registration_type':'operating_notice','target_id':notice,'changes':{'description':'Synthetic Edge correction'}},'admin')
        check('실제 관리자 보정 Edge도 새 원본 경로로 정상 수정한다',reply[0]==200 and query('select description from operating_notice_private.shop_operating_notices where id=%s',(notice,))=='Synthetic Edge correction',http_status=reply[0])

        registered=[]
        for kind in ['operating_notice','full_close','early_close','late_opening']:
            body_edge={'registration_type':'operating_notice','shop_name':shop_name,'notice_type':kind,'description':'Synthetic '+kind,'source_url':f'https://www.instagram.com/p/{marker+kind}/','start_date':'2099-10-01','end_date':'2099-10-31'}
            if kind=='operating_notice':
                body_edge['daily_schedules']=[{'date':'2099-10-12','closed':True,'schedule_override':None}]
            if kind=='early_close':
                body_edge['end_time']='18:00'
            if kind=='late_opening':
                body_edge['start_time']='12:00'
            reply=call('POST','/functions/v1/register-event',body_edge,'admin')
            check('실제 관리자 등록 Edge의 '+kind+' 공지는 정상 저장된다',reply[0]==200 and bool(reply[1].get('id')),http_status=reply[0],code=reply[1].get('code') if isinstance(reply[1],dict) else None)
            registered.append(reply[1]['id'])
            stored=query('select to_jsonb(n) from operating_notice_private.shop_operating_notices n where id=%s',(reply[1]['id'],))
            check(kind+'의 검토 메모와 원본 연결을 보존한다',stored['review_note']=='관리자 미리보기 승인 등록' and bool(stored['raw_post_id']))
            public=call('GET',f'/rest/v1/shop_operating_notices?id=eq.{reply[1]["id"]}')
            check(kind+' 등록 직후 공개 응답에 내부 필드는 없다',public[0]==200 and set(public[1][0])==set(PUBLIC))
        reply=call('GET','/functions/v1/admin-operating-notice',actor='admin')
        check('기존 관리자 지연 오픈 목록과 FK 매장 조회도 정상이다',reply[0]==200 and any(n['id']==registered[-1] for n in reply[1]['notices']))
        first=call('POST','/functions/v1/admin-operating-notice',{'id':registered[-1]},'admin')
        second=call('POST','/functions/v1/admin-operating-notice',{'id':registered[-1]},'admin')
        check('기존 지연 오픈 해제 RPC는 반복 실행도 같은 시각이다',first[0]==200 and second[0]==200 and first[1]['manually_released_at']==second[1]['manually_released_at'])
        check('해제 뒤에도 원본 검토 메모는 보존한다',query('select review_note from operating_notice_private.shop_operating_notices where id=%s',(registered[-1],))=='관리자 미리보기 승인 등록')

        deleted=str(uuid.uuid4())
        repeat={**body,'id':deleted,'description':'Synthetic delete'}
        reply=call('POST','/rest/v1/admin_shop_operating_notice_records',repeat,'service')
        check('service 원본 추가 등록이 가능하다',reply[0]==201)
        reply=call('DELETE',f'/rest/v1/admin_shop_operating_notice_records?id=eq.{deleted}',actor='service')
        check('service 원본 DELETE가 실제 행을 제거한다',reply[0]==204 and query('select count(*) from operating_notice_private.shop_operating_notices where id=%s',(deleted,))==0)
        cascade=str(uuid.uuid4())
        connection.execute('insert into public.instagram_posts_raw(id,shop_id,instagram_username,source_type,source_url,source_key) values (%s,%s,%s,%s,%s,%s)',(cascade,shop,'synthetic','post',f'https://example.invalid/{marker}/cascade',marker+'cascade'))
        repeat={**body,'id':str(uuid.uuid4()),'raw_post_id':cascade}
        call('POST','/rest/v1/admin_shop_operating_notice_records',repeat,'service')
        connection.execute('delete from public.instagram_posts_raw where id=%s',(cascade,))
        check('raw post 삭제 FK cascade도 원본과 공개 뷰에 함께 반영된다',query('select count(*) from operating_notice_private.shop_operating_notices where id=%s',(repeat['id'],))==0)
    except Exception as error:
        failure={'type':type(error).__name__,'message':str(error) if isinstance(error,AssertionError) else '테스트 실행 오류','sqlstate':getattr(error,'sqlstate',None)}
    finally:
        for shop in shops:
            connection.execute('delete from public.ramen_shops where id=%s',(shop,))
        for actor in ['A','B']:
            account=accounts.get(actor)
            if account:
                reply=call('DELETE','/auth/v1/admin/users/'+account['id'],actor='service')
                if reply[0] not in [200,204]:
                    failure={'type':'CleanupError','message':'합성 Auth 계정 삭제 실패'}
        final=snapshot()
        connection.close()
        report={'cases':cases,'passed_cases':sum(c['passed'] for c in cases),'HTTP_requests':requests,'failure':failure,'baseline_restored':baseline==final,'baseline':baseline,'final':final,'test_accounts_created':len([a for a in ['A','B'] if a in accounts]),'password_logins':logins,'existing_admin_account_reused':True,'actual_provider_calls':0,'actual_notifications':0,'production_requests':0,'public_fields':PUBLIC,'hidden_fields':INTERNAL}
        Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:report[k] for k in ['passed_cases','HTTP_requests','failure','baseline_restored']},ensure_ascii=False))
        if failure or baseline!=final:
            raise SystemExit(1)

if __name__=='__main__':
    main()
