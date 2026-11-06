"""Hosted staging에서 프로필 Instagram 제거와 자기소개 오류 응답을 확인한다."""
import argparse
import json
import os
import secrets
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import psycopg

REF = 'gedptwzjortijxpjvmbc'
RPC = '/rest/v1/rpc/update_my_profile'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        return None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=['before', 'after', 'cleanup'], required=True)
    for name in ['config','db-url-file','db-password-file','state','output']:
        parser.add_argument('--'+name, required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    db_url = Path(args.db_url_file).read_text().strip()
    assert config['project_ref'] == REF and REF in db_url and config['url'].rstrip('/') == 'https://'+REF+'.supabase.co'
    connection = psycopg.connect(db_url, password=Path(args.db_password_file).read_text().strip(), autocommit=True, connect_timeout=20)
    connection.execute("set statement_timeout='10s'")
    state_path = Path(args.state)
    state = {'users':{},'project_ref':REF} if args.phase == 'before' else json.loads(state_path.read_text())
    assert state['project_ref'] == REF
    if args.phase == 'before':
        assert not state_path.exists()
    cases, requests = [], 0
    keep, failure, final = False, None, None
    opener = urllib.request.build_opener(NoRedirect)

    def query(sql, params=()):
        return connection.execute(sql, params or None).fetchone()[0]

    def check(name, value, **details):
        cases.append({'case':name,'passed':bool(value),**details})
        assert value, name

    def save():
        with os.fdopen(os.open(state_path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600),'w') as f:
            json.dump(state,f)
        state_path.chmod(0o600)

    def call(path, body=None, actor='A', method='POST'):
        nonlocal requests
        requests += 1
        key = config['service_role'] if actor == 'service' else config['anon']
        token = key if actor in ['service','anon'] else state['users'][actor]['token']
        request = urllib.request.Request(config['url'].rstrip('/')+path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'apikey':key,'Authorization':'Bearer '+token,'Content-Type':'application/json'})
        try:
            response = opener.open(request,timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None, dict(response.headers)

    def snapshot():
        return query("""select jsonb_build_object(
          'profiles',(select jsonb_build_object('rows',count(*),'digest',encode(extensions.digest(coalesce(jsonb_agg(to_jsonb(p)-'instagram_username' order by user_id)::text,'[]'),'sha256'),'hex')) from public.public_profiles p),
          'users',(select count(*) from auth.users),'requests',(select count(*) from account_profile_private.profile_request_events),
          'daily',(select count(*) from account_profile_private.profile_daily_change_counts),
          'storage',(select count(*) from storage.objects),'pushes',(select count(*) from public.push_registrations))""")

    def profile(actor='A'):
        return query("select to_jsonb(p)-'instagram_username' from public.public_profiles p where user_id=%s",(state['users'][actor]['id'],))

    def clear_requests(actor='A'):
        connection.execute('delete from account_profile_private.profile_request_events where user_id=%s',(state['users'][actor]['id'],))

    def clear_daily(actor='A'):
        connection.execute('delete from account_profile_private.profile_daily_change_counts where user_id=%s',(state['users'][actor]['id'],))

    def counts(actor='A'):
        return query("select coalesce(jsonb_agg(to_jsonb(c) order by change_date),'[]') from account_profile_private.profile_daily_change_counts c where user_id=%s",(state['users'][actor]['id'],))

    def payload(**values):
        return {'p_user_id':state['users']['A']['id'],'p_nickname':state['users']['A']['nickname'],**values}

    def error(reply, status, code):
        return reply[0] == status and reply[1] == {'code':code,'message':code}

    try:
        if args.phase == 'before':
            state['baseline'] = snapshot()
            save()
            for actor in ['A','B']:
                password = secrets.token_urlsafe(30)
                email = 'profile.'+uuid.uuid4().hex+'@example.invalid'
                reply = call('/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True},'service')
                check(actor+' 합성 계정 생성',reply[0]==200 and bool(reply[1].get('id')))
                state['users'][actor] = {'id':reply[1]['id'],'nickname':'검사'+uuid.uuid4().hex[:8]}
                save()
                reply = call('/auth/v1/token?grant_type=password',{'email':email,'password':password},'anon')
                check(actor+' 한 번 로그인한 세션 재사용',reply[0]==200 and bool(reply[1].get('access_token')))
                state['users'][actor]['token'] = reply[1]['access_token']
                save()
                reply = call('/rest/v1/rpc/fetch_or_create_my_profile',{'p_user_id':state['users'][actor]['id']},actor)
                check(actor+' 합성 프로필 생성과 기존 Instagram 응답 확인',reply[0]==200 and 'instagram_username' in reply[1])
                connection.execute("update public.public_profiles set nickname=%s,bio='원본 소개',instagram_username='synthetic_profile',approved_at=now() where user_id=%s",(state['users'][actor]['nickname'],state['users'][actor]['id']))
            original = profile()
            for name,body in [('31자 자기소개',payload(p_bio='가'*31)),('줄바꿈 자기소개',payload(p_bio='라멘\n좋아요'))]:
                reply = call(RPC,body)
                check('수정 전 '+name+'는 저장 없이 서버 오류',error(reply,500,'PROFILE_REQUEST_FAILED') and profile()==original and counts()==[],http_status=reply[0])
            state['fixture'] = snapshot()
            state['before_cases'] = len(cases)
            state['before_requests'] = requests
            save()
            keep = True
        elif args.phase == 'after':
            check('migration은 Instagram 외 합성 프로필과 제한 기록을 보존',snapshot()==state['fixture'])
            original = profile()
            values = [('한글31자','가'*31),('영문31자','a'*31),('이모지31개','🍜'*31)] + [('금지 줄바꿈 U+'+format(ord(c),'04X'),'앞'+c+'뒤') for c in '\n\r\v\f\x85\u2028\u2029']
            for name,value in values:
                clear_requests()
                reply = call(RPC,payload(p_bio=value))
                check(name+'는 안전한400과 고정 오류 코드',error(reply,400,'PROFILE_INVALID_BIO'),http_status=reply[0])
                check(name+' 거절은 프로필과 일일 변경 횟수를 보존',profile()==original and counts()==[])
            clear_requests()
            for _ in range(5):
                check('잘못된 자기소개도 요청 횟수에 포함',error(call(RPC,payload(p_bio='x'*31)),400,'PROFILE_INVALID_BIO'))
            reply = call(RPC,payload(p_bio='x'*31))
            check('여섯 번째 요청은 기존429와 재시도 시간을 유지',reply[0]==429 and reply[1].get('code')=='PROFILE_SAVE_RATE_LIMIT' and int(next(v for k,v in reply[2].items() if k.lower()=='retry-after'))>0)
            clear_requests()
            for name,value in [('한글30자','가'*30),('이모지30개','🍜'*30)]:
                clear_daily()
                reply = call(RPC,payload(p_bio=value))
                check(name+' 정상 저장과 Instagram 없는 응답',reply[0]==200 and reply[1]['bio']==value and 'instagram_username' not in reply[1])
            check('실제 소개 변경은 승인 상태 초기화를 유지',profile()['approved_at'] is None)
            clear_requests();clear_daily()
            reply=call(RPC,payload(p_bio='변경 소개'))
            check('정상 자기소개 변경 첫 회는200',reply[0]==200 and reply[1]['bio_changes_remaining']==1)
            before_null=profile()
            for body in [payload(),payload(p_bio=None)]:
                reply=call(RPC,body)
                check('자기소개 생략과null은 기존 내용과횟수 보존',reply[0]==200 and reply[1]['bio']=='변경 소개' and reply[1]['bio_changes_remaining']==1 and profile()==before_null)
            reply=call(RPC,payload(p_bio=''))
            check('빈 자기소개 저장으로 제거 가능',reply[0]==200 and reply[1]['bio']=='' and reply[1]['bio_changes_remaining']==0)
            reply=call(RPC,payload(p_bio='세 번째 변경'))
            check('자기소개 일일 두 번 변경 제한 유지',reply[0]==429 and reply[1]['code']=='PROFILE_BIO_DAILY_LIMIT' and profile()['bio']=='')
            clear_requests();clear_daily()
            other_before=profile('B'); own_before=profile()
            reply=call(RPC,payload(p_bio='타인 변경'),actor='B')
            check('다른 회원의 프로필 변경은403과 무변경',reply[0]==403 and profile()==own_before and profile('B')==other_before)
            reply=call(RPC,payload(p_nickname=state['users']['B']['nickname']))
            check('중복 닉네임은 기존409',error(reply,409,'PROFILE_NICKNAME_TAKEN') and profile()==own_before and counts()==[])
            reply=call(RPC,payload(p_nickname='x'))
            check('잘못된 닉네임은 기존400',reply[0]==400 and profile()==own_before)
            reply=call(RPC,payload(p_remove_photo=None))
            check('잘못된 사진 제거 인자는 기존400',reply[0]==400 and profile()==own_before)
            clear_requests()
            connection.execute('update public.public_profiles set suspended_at=now() where user_id=%s',(state['users']['A']['id'],))
            reply=call(RPC,payload(p_bio='정지 계정'))
            check('정지 계정은403으로 차단',reply[0]==403 and profile()['bio']==own_before['bio'])
            connection.execute('update public.public_profiles set suspended_at=null where user_id=%s',(state['users']['A']['id'],))
            clear_requests()
            for actor in ['A','anon','service']:
                reply=call(RPC,payload(p_instagram_username='removed_feature'),actor)
                check(actor+' 구형 Instagram 인자는 제거된 서명으로 거절',reply[0]==404 and reply[1].get('code')=='PGRST202')
            for actor in ['A','B']:
                reply=call('/rest/v1/rpc/fetch_or_create_my_profile',{'p_user_id':state['users'][actor]['id']},actor)
                check(actor+' 현재 프로필 응답에서 Instagram 제거',reply[0]==200 and 'instagram_username' not in reply[1] and reply[1]['user_id']==state['users'][actor]['id'])
            reply=call('/rest/v1/public_profiles?select=instagram_username&user_id=eq.'+state['users']['A']['id'],actor='service',method='GET')
            check('서버 직접 컬럼 조회도 제거된 필드400',reply[0]==400 and reply[1].get('code')=='42703')
            for actor in ['anon','service']:
                reply=call(RPC,payload(p_bio='권한 없음'),actor)
                check(actor+' 사용자 없는 호출은 거절',reply[0] in [401,403])
            clear_requests();clear_daily()
            for i in range(2):
                new_name='검사'+uuid.uuid4().hex[:8]
                reply=call(RPC,payload(p_nickname=new_name))
                check('닉네임 정상 변경과 횟수 차감 유지',reply[0]==200 and reply[1]['nickname']==new_name and reply[1]['nickname_changes_remaining']==1-i)
            reply=call(RPC,payload(p_nickname='검사'+uuid.uuid4().hex[:8]))
            check('닉네임 세 번째 변경은429',reply[0]==429 and reply[1]['code']=='PROFILE_NICKNAME_DAILY_LIMIT')
            clear_requests();clear_daily()
            before_rollback=snapshot()
            with connection.transaction():
                connection.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'sub':state['users']['A']['id'],'role':'authenticated'}),))
                connection.execute('set local role authenticated')
                value=query('select public.update_my_profile(%s,%s,null,false,%s)',(state['users']['A']['id'],state['users']['A']['nickname'],'롤백 소개'))
                check('서버 트랜잭션에서 새5인자 함수 정상',value.get('bio')=='롤백 소개' and 'instagram_username' not in value)
                raise psycopg.Rollback
            check('명시적 트랜잭션 취소는 프로필과 제한 기록 복원',snapshot()==before_rollback)
            check('새 컬럼 제약에서도 Instagram 의존성이 없음',query("select count(*) from information_schema.columns where table_schema='public' and table_name='public_profiles' and column_name='instagram_username'")==0)
            check('게시물 수집용 동명 컬럼은 유지',query("select count(*) from information_schema.columns where table_schema='public' and table_name='instagram_posts_raw' and column_name='instagram_username'")==1)
    except Exception as error:
        failure=type(error).__name__+(': '+str(error) if isinstance(error,AssertionError) else '')
        keep=False
    finally:
        if not keep and 'baseline' in state:
            try:
                for user in state['users'].values():
                    reply=call('/auth/v1/admin/users/'+user['id'],actor='service',method='DELETE')
                    check('합성 계정과 세션 정리',reply[0] in [200,404])
                final=snapshot()
                check('프로필과 제한 기록 및 기타 집계 baseline 복원',final==state['baseline'])
                state_path.unlink(missing_ok=True)
            except Exception as error:
                failure=(failure+'; ' if failure else '')+'cleanup '+type(error).__name__
                save()
        report={'phase':args.phase,'cases':cases,'passed_cases':sum(c['passed'] for c in cases),'HTTP_requests':requests,'failure':failure,'baseline':state.get('baseline'),'final':final,'baseline_restored':final==state.get('baseline') if final else False,'fixtures_retained':keep,'before_cases':state.get('before_cases'),'before_requests':state.get('before_requests'),'password_logins':2 if args.phase=='before' else 0,'production_requests':0,'provider_calls':0,'notifications':0}
        Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k not in ['cases','baseline','final']},ensure_ascii=False))
        connection.close()
    if failure:
        raise SystemExit(1)

if __name__=='__main__':
    main()
