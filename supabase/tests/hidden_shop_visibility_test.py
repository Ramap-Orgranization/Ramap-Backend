#!/usr/bin/env python3
"""격리 staging에서 숨김 가게의 공개 우회·공개 조회·서버 유지보수를 검증한다."""
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

STAGING = 'gedptwzjortijxpjvmbc'
TABLES = ['ramen_shops','shop_menu_sections','shop_menu_items','shop_events',
          'shop_event_participants','shop_operating_status','shop_bookmark_counts',
          'shop_menu_exclusion_rules','shop_menu_update_timestamps','external_venues',
          'user_shop_bookmarks','user_shop_menu_recommendations','instagram_posts_raw',
          'public_profiles']
PUBLIC_NOTICE_FIELDS = {'id','shop_id','notice_type','description','notice_date',
                       'start_time','end_time','source_url','created_at','updated_at',
                       'end_date','schedule_override','manually_released_at','daily_schedules'}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,request,response,code,message,headers,newurl):
        return None

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase',choices=['before','after','cleanup'],required=True)
    for name in ['config','db-url-file','db-password-file','state','output']:
        parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    config=json.loads(Path(args.config).read_text())
    dburl=Path(args.db_url_file).read_text().strip()
    assert config['project_ref']==STAGING and STAGING in dburl, '운영 fixture 생성은 금지합니다'
    assert config['url'].rstrip('/')==f'https://{STAGING}.supabase.co'
    connection=psycopg.connect(dburl,password=Path(args.db_password_file).read_text().strip(),autocommit=True,connect_timeout=20)
    connection.execute("set statement_timeout='10s'")
    opener=urllib.request.build_opener(NoRedirect)
    state_path=Path(args.state)
    state=json.loads(state_path.read_text()) if args.phase!='before' else {'project_ref':STAGING,'shops':{},'users':{},'ids':{},'before_cases':[],'requests':0}
    assert state['project_ref']==STAGING, 'staging 상태 파일만 사용합니다'
    cases=[]
    requests=0
    failure=None
    keep=False

    def query(sql,values=()):
        return connection.execute(sql,values or None).fetchone()[0]

    def save_state():
        descriptor=os.open(state_path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(descriptor,'w') as output:
            json.dump(state,output)
        state_path.chmod(0o600)

    def check(name,condition,**details):
        cases.append({'case':name,'passed':bool(condition),**details})
        if not condition:
            raise AssertionError(name)

    def call(method,path,body=None,actor='anon',headers=None):
        nonlocal requests
        key=config['service_role'] if actor=='service' else config['anon']
        token=key if actor in ['service','anon'] else state['users'][actor]['token']
        request=urllib.request.Request(config['url'].rstrip('/')+path,method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'apikey':key,'Authorization':'Bearer '+token,'Content-Type':'application/json',**(headers or {})})
        requests+=1
        try:
            response=opener.open(request,timeout=20)
        except urllib.error.HTTPError as error:
            response=error
        with response:
            data=response.read()
            return response.status,json.loads(data) if data else None

    def snapshot():
        tables=TABLES+['operating_notice_private.shop_operating_notices']
        rows={}
        for name in tables:
            table=name if '.' in name else 'public.'+name
            rows[name]=query("select jsonb_build_object('rows',count(*),'digest',encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text)::text,'[]'),'sha256'),'hex')) from "+table+' x')
        rows['auth_users']=query('select count(*) from auth.users')
        rows['storage_objects']=query('select count(*) from storage.objects')
        rows['push_registrations']=query('select count(*) from public.push_registrations')
        return rows

    def cleanup():
        shops=list(state['shops'].values())
        if shops:
            # Existing menu-update triggers need the parent until child deletion finishes.
            connection.execute('delete from public.shop_menu_items where section_id in (select id from public.shop_menu_sections where shop_id=any(%s::uuid[]))',(shops,))
            connection.execute('delete from public.shop_menu_sections where shop_id=any(%s::uuid[])',(shops,))
            connection.execute('delete from public.ramen_shops where id=any(%s::uuid[])',(shops,))
        external=state['ids'].get('external_venue')
        if external:
            connection.execute('delete from public.shop_events where external_venue_id=%s',(external,))
            connection.execute('delete from public.external_venues where id=%s',(external,))
        for user in state['users'].values():
            reply=call('DELETE','/auth/v1/admin/users/'+user['id'],actor='service')
            check('합성 계정과 세션을 정리한다',reply[0] in [200,404])
        final=snapshot()
        check('합성 자료 제거 후 baseline 집계·내용을 복원한다',final==state['baseline'])
        return final

    def rpc(name,parameters,actor='anon',method='POST'):
        suffix='?'+urllib.parse.urlencode({k:('{'+','.join(v)+'}') if isinstance(v,list) else v for k,v in parameters.items()}) if method=='GET' else ''
        return call(method,'/rest/v1/rpc/'+name+suffix,parameters if method=='POST' else None,actor)

    def assert_empty(name,reply):
        check(name,reply[0]==200 and reply[1]==[],http_status=reply[0])

    def read_paths(shop,label):
        section=state['ids'][label+'_section']
        event=state['ids'][label+'_event']
        return {
            'ramen_shops':f'ramen_shops?id=eq.{shop}',
            'shop_menu_sections':f'shop_menu_sections?shop_id=eq.{shop}',
            'shop_menu_items':f'shop_menu_items?section_id=eq.{section}',
            'visible_shop_menu_items':f'visible_shop_menu_items?shop_id=eq.{shop}',
            'shop_events':f'shop_events?id=eq.{event}',
            'active_events_v2':f'active_events_v2?id=eq.{event}',
            'active_shop_events':f'active_shop_events?shop_context_id=eq.{shop}',
            'active_shop_events_v2':f'active_shop_events_v2?shop_context_id=eq.{shop}',
            'shop_event_participants':f'shop_event_participants?shop_id=eq.{shop}',
            'shop_operating_status':f'shop_operating_status?shop_id=eq.{shop}',
            'shop_waiting_systems':f'shop_waiting_systems?shop_id=eq.{shop}',
            'shop_operating_notices':f'shop_operating_notices?shop_id=eq.{shop}',
            'shop_bookmark_counts':f'shop_bookmark_counts?shop_id=eq.{shop}',
            'shop_menu_exclusion_rules':f'shop_menu_exclusion_rules?shop_id=eq.{shop}',
            'shop_menu_duplicate_candidates':f'shop_menu_duplicate_candidates?shop_id=eq.{shop}',
        }

    try:
        assert query('select count(*) from cron.job where active')==0, '크론이 중단된 staging만 사용합니다'
        assert query("select count(*) from vault.secrets where name ilike '%webhook%' or name ilike '%discord%'")==0
        if args.phase=='before':
            assert not state_path.exists(), '이전 fixture 상태를 덮어쓰지 않습니다'
            state['baseline']=snapshot()
            save_state()
            marker=uuid.uuid4().hex
            for actor in ['A','B']:
                password=secrets.token_urlsafe(30)
                email=f'visibility.{marker}.{actor}@example.invalid'
                reply=call('POST','/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True,'user_metadata':{'is_admin':True,'role':'service_role'}},'service')
                check(actor+' 합성 계정을 만든다',reply[0]==200 and bool(reply[1].get('id')))
                state['users'][actor]={'id':reply[1]['id']};save_state()
                reply=call('POST','/auth/v1/token?grant_type=password',{'email':email,'password':password})
                check(actor+'는 한번 로그인한 세션을 재사용한다',reply[0]==200 and bool(reply[1].get('access_token')))
                state['users'][actor]['token']=reply[1]['access_token'];save_state()
            for label in ['visible','hidden','collaborator']:
                shop=str(uuid.uuid4());state['shops'][label]=shop;save_state()
                connection.execute('insert into public.ramen_shops(id,name,address,lat,lng,is_visible,menu_snapshot_enabled,waiting_provider,waiting_provider_url) values (%s,%s,%s,37,127,%s,false,%s,%s)',(shop,'Synthetic '+label+' '+marker,'Synthetic only',label!='hidden','naver',f'https://example.invalid/wait/{label}'))
            for label in ['visible','hidden']:
                shop=state['shops'][label]
                section=str(uuid.uuid4());event=str(uuid.uuid4());raw=str(uuid.uuid4())
                state['ids'].update({label+'_section':section,label+'_event':event});save_state()
                connection.execute('insert into public.shop_menu_sections(id,shop_id,title,is_visible) values (%s,%s,%s,true)',(section,shop,'Synthetic regular'))
                connection.execute("insert into public.shop_events(id,shop_id,title,description,start_date,end_date,source_url,event_type) values (%s,%s,%s,%s,current_date-1,current_date+30,%s,'collab')",(event,shop,'Synthetic '+label,'Synthetic only',f'https://example.invalid/{marker}/{label}'))
                for name in [label,label+'라멘']:
                    menu=str(uuid.uuid4())
                    state['ids'].setdefault(label+'_menus',[]).append(menu)
                    connection.execute('insert into public.shop_menu_items(id,section_id,name,price_krw) values (%s,%s,%s,9000)',(menu,section,name))
                connection.execute('insert into public.shop_operating_status(shop_id,source_url,status) values (%s,%s,%s)',(shop,f'https://example.invalid/{label}','open'))
                connection.execute('insert into public.shop_bookmark_counts(shop_id,like_count) values (%s,2)',(shop,))
                connection.execute("insert into public.shop_menu_exclusion_rules(shop_id,match_type,match_value,reason) values (%s,'name_contains','Synthetic','Synthetic only')",(shop,))
                connection.execute("insert into public.instagram_posts_raw(id,shop_id,instagram_username,source_type,source_url,source_key) values (%s,%s,'synthetic','post',%s,%s)",(raw,shop,f'https://example.invalid/{marker}/{label}',marker+label))
                connection.execute("insert into operating_notice_private.shop_operating_notices(shop_id,raw_post_id,notice_type,description,notice_date,end_date,source_url,ocr_text,review_note) values (%s,%s,'full_close','Synthetic public',current_date,current_date+30,%s,'SYNTHETIC PRIVATE','SYNTHETIC NOTE')",(shop,raw,f'https://example.invalid/{label}'))
            visible=state['shops']['visible'];hidden=state['shops']['hidden']
            for label in ['hidden_section','expired']:
                section=str(uuid.uuid4());state['ids'][label+'_section']=section;save_state()
                connection.execute('insert into public.shop_menu_sections(id,shop_id,title,is_visible) values (%s,%s,%s,%s)',(section,visible,'Synthetic '+label,label!='hidden_section'))
                expired=str(uuid.uuid4()) if label=='expired' else None
                if expired:
                    connection.execute("insert into public.shop_events(id,shop_id,title,description,start_date,end_date,source_url,event_type) values (%s,%s,'Synthetic expired','Synthetic only',current_date-10,current_date-2,%s,'limited_menu')",(expired,visible,f'https://example.invalid/{marker}/expired'))
                for name in [label,label+'라멘']:
                    menu=str(uuid.uuid4());state['ids'].setdefault(label+'_menus',[]).append(menu)
                    connection.execute('insert into public.shop_menu_items(id,section_id,name,price_krw,event_id) values (%s,%s,%s,9000,%s)',(menu,section,name,expired))
            for label in ['visible','hidden','hidden_section','expired']:
                connection.execute('insert into public.user_shop_menu_recommendations(user_id,menu_id) values (%s,%s)',(state['users']['A']['id'],state['ids'][label+'_menus'][0]))
            external=str(uuid.uuid4());external_event=str(uuid.uuid4())
            state['ids'].update({'external_venue':external,'external_event':external_event});save_state()
            connection.execute('insert into public.external_venues(id,name) values (%s,%s)',(external,'Synthetic external'))
            connection.execute("insert into public.shop_events(id,external_venue_id,venue_name,title,description,start_date,end_date,source_url,event_type) values (%s,%s,'Synthetic external','Synthetic external','Synthetic only',current_date-1,current_date+30,%s,'popup')",(external_event,external,f'https://example.invalid/{marker}/external'))
            for event,participant in [(state['ids']['visible_event'],hidden),(state['ids']['visible_event'],state['shops']['collaborator']),(state['ids']['hidden_event'],visible),(external_event,hidden),(external_event,visible)]:
                connection.execute('insert into public.shop_event_participants(event_id,shop_id) values (%s,%s)',(event,participant))
            connection.execute("insert into public.shop_event_participants(event_id,external_name) values (%s,'Synthetic external collaborator')",(state['ids']['visible_event'],))
            save_state()
            for name,path in read_paths(hidden,'hidden').items():
                reply=call('GET','/rest/v1/'+path)
                check('수정 전 '+name+' 숨김 가게 공개 우회를 재현한다',reply[0]==200 and bool(reply[1]),http_status=reply[0])
            reply=rpc('fetch_shop_detail_v2',{'p_shop_id':hidden})
            check('수정 전 상세 RPC의 숨김 가게 공개를 재현한다',reply[0]==200 and len(reply[1])==1)
            reply=rpc('fetch_menu_recommendation_counts',{'p_menu_ids':[state['ids'][label+'_menus'][0] for label in ['visible','hidden','hidden_section','expired']]})
            check('수정 전 추천 집계는 공개 메뉴 범위 밖도 반환한다',reply[0]==200 and len(reply[1])==4)
            reply=rpc('fetch_shop_menu_updated_at',{'p_shop_id':hidden})
            check('수정 전 숨김 가게의 메뉴 갱신 시각을 반환한다',reply[0]==200 and isinstance(reply[1],str))
            state['before_cases']=cases;state['requests']=requests;save_state();keep=True
        elif args.phase=='after':
            visible=state['shops']['visible'];hidden=state['shops']['hidden']
            for actor in ['anon','A','B']:
                for name,path in read_paths(hidden,'hidden').items():
                    assert_empty(actor+' '+name+'에서 숨김 가게와 연결 자료가 안 보인다',call('GET','/rest/v1/'+path,actor=actor))
                for name in ['fetch_shop_detail','fetch_shop_detail_v2']:
                    for method in ['GET','POST']:
                        assert_empty(actor+' '+name+' '+method+' 숨김 상세 조회가 비어 있다',rpc(name,{'p_shop_id':hidden},actor,method))
                for method in ['GET','POST']:
                    reply=rpc('fetch_shop_menu_updated_at',{'p_shop_id':hidden},actor,method)
                    check(actor+' '+method+' 숨김 메뉴 갱신 시각도 null이다',reply[0]==200 and reply[1] is None)
                    reply=rpc('fetch_menu_recommendation_counts',{'p_menu_ids':[state['ids'][label+'_menus'][0] for label in ['visible','hidden','hidden_section','expired']]},actor,method)
                    check(actor+' '+method+' 추천 집계는 공개 메뉴 하나만 반환한다',reply[0]==200 and reply[1]==[{'menu_id':state['ids']['visible_menus'][0],'recommendation_count':1}])
                reply=call('GET',f'/rest/v1/ramen_shops?id=in.({hidden},{visible})',actor=actor)
                check(actor+' ID 목록을 섞어도 공개 가게만 반환한다',reply[0]==200 and [r['id'] for r in reply[1]]==[visible])
                reply=call('GET',f'/rest/v1/ramen_shops?id=eq.{hidden}&select=id,shop_menu_sections(*,shop_menu_items(*))',actor=actor)
                assert_empty(actor+' 관계 임베딩으로 숨김 가게를 우회하지 못한다',reply)
                reply=call('GET',f'/rest/v1/shop_event_participants?event_id=eq.{state["ids"]["hidden_event"]}',actor=actor)
                assert_empty(actor+' 숨김 행사에 연결된 공개 가게 참여자도 감춘다',reply)
                reply=call('GET',f'/rest/v1/active_events_v2?id=eq.{state["ids"]["visible_event"]}',actor=actor)
                check(actor+' 공개 행사에는 공개 협업 가게와 외부 참여자만 포함한다',reply[0]==200 and len(reply[1])==1 and [s['id'] for s in reply[1][0]['collaborator_shops']]==[state['shops']['collaborator']] and len(reply[1][0]['external_participants'])==1)
                reply=call('GET',f'/rest/v1/active_events_v2?id=eq.{state["ids"]["external_event"]}',actor=actor)
                check(actor+' 매장 없는 외부 장소 행사는 유지하고 숨김 협업 가게만 감춘다',reply[0]==200 and len(reply[1])==1 and reply[1][0]['venue_shop'] is None and [s['id'] for s in reply[1][0]['collaborator_shops']]==[visible])
                reply=call('GET',f'/rest/v1/active_shop_events_v2?shop_context_id=eq.{state["shops"]["collaborator"]}',actor=actor)
                check(actor+' 공개 협업 가게의 행사 연결은 유지한다',reply[0]==200 and [r['id'] for r in reply[1]]==[state['ids']['visible_event']])
                reply=call('GET',f'/rest/v1/shop_operating_notices?shop_id=eq.{visible}',actor=actor)
                check(actor+' 공개 공지는 기존14필드를 유지한다',reply[0]==200 and len(reply[1])==1 and set(reply[1][0])==PUBLIC_NOTICE_FIELDS)
                reply=call('GET',f'/rest/v1/shop_menu_duplicate_candidates?shop_id=eq.{visible}',actor=actor)
                check(actor+' 중복 메뉴 뷰는 공개 섹션·현재 메뉴만 집계한다',reply[0]==200 and len(reply[1])==1 and set(reply[1][0]['menu_item_ids'])==set(state['ids']['visible_menus']))
                reply=rpc('fetch_shop_detail_v2',{'p_shop_id':visible},actor)
                check(actor+' 공개 상세의 가게·공지·메뉴·대기 데이터가 유지된다',reply[0]==200 and len(reply[1])==1 and reply[1][0]['shop']['id']==visible and len(reply[1][0]['menu_items'])==2 and set(reply[1][0]['operating_notice'])==PUBLIC_NOTICE_FIELDS and bool(reply[1][0]['waiting_system']))
                for method in ['PATCH','DELETE']:
                    reply=call(method,f'/rest/v1/ramen_shops?id=eq.{hidden}',{'is_visible':True} if method=='PATCH' else None,actor)
                    check(actor+' '+method+'로 숨김 상태를 바꾸거나 삭제하지 못한다',reply[0] in [200,204,401,403] and query('select is_visible from public.ramen_shops where id=%s',(hidden,)) is False)
            for name,path in read_paths(hidden,'hidden').items():
                reply=call('GET','/rest/v1/'+path,actor='service')
                check('신뢰된 서버 '+name+' 조회는 숨김 데이터도 유지한다',reply[0]==200 and bool(reply[1]))
            reply=call('GET',f'/rest/v1/admin_shop_operating_notice_records?shop_id=eq.{hidden}',actor='service')
            check('서버 관리자 원본 공지는 숨김 가게의 내부 자료도 유지한다',reply[0]==200 and reply[1][0]['ocr_text']=='SYNTHETIC PRIVATE')
            reply=call('PATCH',f'/rest/v1/admin_shop_operating_notice_records?shop_id=eq.{hidden}',{'description':'Synthetic updated'},'service',{'Prefer':'return=representation'})
            check('서버는 숨김 공지도 수정할 수 있다',reply[0]==200 and reply[1][0]['description']=='Synthetic updated')
            reply=call('PATCH',f'/rest/v1/ramen_shops?id=eq.{hidden}',{'is_visible':True},'service')
            check('서버의 공개 전환은 성공한다',reply[0]==204)
            for name,path in read_paths(hidden,'hidden').items():
                reply=call('GET','/rest/v1/'+path)
                check('공개 전환 후 '+name+'가 다시 조회된다',reply[0]==200 and bool(reply[1]))
            reply=call('PATCH',f'/rest/v1/ramen_shops?id=eq.{hidden}',{'is_visible':False},'service')
            check('서버의 숨김 복귀는 성공한다',reply[0]==204)
            assert_empty('같은 로그인 세션에서도 숨김 복귀가 즉시 적용된다',call('GET',f'/rest/v1/ramen_shops?id=eq.{hidden}',actor='A'))
            with connection.transaction():
                connection.execute('create policy synthetic_permissive_read on public.ramen_shops for select to anon using (true)')
                connection.execute('set local role anon')
                check('추가 허용 정책으로도 restrictive 숨김 경계를 우회하지 못한다',query('select count(*) from public.ramen_shops where id=%s',(hidden,))==0)
                connection.execute('reset role')
                connection.execute('drop policy synthetic_permissive_read on public.ramen_shops')
            for actor in ['anon','A','B']:
                reply=call('GET',f'/rest/v1/admin_shop_operating_notice_records?shop_id=eq.{hidden}',actor=actor)
                check(actor+' 관리자 원본 경로로 우회하지 못한다',reply[0] in [401,403] and reply[1].get('code')=='42501')
        else:
            check('중단된 검사의 fixture 정리를 요청했다',True)
    except Exception as error:
        failure=type(error).__name__+': '+str(error) if isinstance(error,AssertionError) else type(error).__name__
        keep=False
    finally:
        final=None
        if not keep and 'baseline' in state:
            try:
                final=cleanup()
                state_path.unlink(missing_ok=True)
            except Exception as error:
                failure=(failure+'; ' if failure else '')+'cleanup '+type(error).__name__
                save_state()
        report={'phase':args.phase,'cases':cases,'passed_cases':sum(c['passed'] for c in cases),'HTTP_requests':requests,
                'before_passed_cases':sum(c['passed'] for c in state['before_cases']), 'before_HTTP_requests':state['requests'],
                'failure':failure,'fixture_retained_for_migration':keep,'baseline':state.get('baseline'),'final':final,
                'baseline_restored':final==state.get('baseline') if final is not None else False,
                'password_logins':2 if args.phase=='before' else 0,'production_requests':0,'actual_provider_calls':0,'actual_notifications':0}
        Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k not in ['cases','baseline','final']},ensure_ascii=False))
        connection.close()
    if failure:
        raise SystemExit(1)

if __name__=='__main__':
    main()
