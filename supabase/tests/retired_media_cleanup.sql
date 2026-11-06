\set ON_ERROR_STOP on
begin;
create function pg_temp.check_true(value boolean,label text) returns void language plpgsql as $$begin
 if value is distinct from true then raise exception 'FAIL: %',label; end if; end$$;

select set_config('request.jwt.claim.role','service_role',false);
select pg_temp.check_true((select not deleted and retired_at is not null from media_private.locations where media_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd' and provider='gcs'),'사용 중단과 실제 삭제 상태를 분리');
select pg_temp.check_true((select state='deleting' from media_private.objects where id='10000000-0000-4000-8000-000000000001'),'기존 삭제 완료 이력은 공개 부활 없이 정리 재개');
select pg_temp.check_true((select state='deleting' from media_private.objects where id='10000000-0000-4000-8000-000000000003'),'이미 탈퇴한 소유자의 잔존 파일도 정리');
select pg_temp.check_true((select state='ready' from media_private.objects where id='10000000-0000-4000-8000-000000000002'),'활성 계정의 보존 원본은 삭제하지 않음');
select pg_temp.check_true(not exists(select 1 from media_private.cleanup where media_id='10000000-0000-4000-8000-000000000002'),'평상시 원본 보존 정책 유지');
select pg_temp.check_true(public.account_has_external_media('11111111-1111-4111-8111-111111111111'),'은퇴한 파일도 계정 삭제 완료 검사에 포함');

-- A request scoped to the first account must neither claim nor expire the second account's uploads.
insert into media_private.objects(id,bucket,path,owner_id,state,upload_expires_at,byte_size,content_type) values
 ('20000000-0000-4000-8000-000000000001','profile-avatars','22222222-2222-4222-8222-222222222222/pending.jpg','22222222-2222-4222-8222-222222222222','pending',now()-interval '1 hour',100,'image/jpeg');
do $$
declare jobs jsonb; job jsonb; claimed_id bigint;
begin
 jobs:=public.claim_account_media_cleanup('11111111-1111-4111-8111-111111111111',100);
 perform pg_temp.check_true(jsonb_array_length(jobs)=1,'해당 계정의 파일만 claim');
 job:=jobs->0;
 perform pg_temp.check_true(job->>'media_id'='10000000-0000-4000-8000-000000000001' and job->>'provider'='gcs' and job->>'generation'='123','기존 저장소 삭제에 필요한 실제 위치와 세대 유지');
 claimed_id:=(job->>'id')::bigint;
 perform pg_temp.check_true(public.claim_account_media_cleanup('11111111-1111-4111-8111-111111111111',100)='[]','다른 worker가 처리 중인 lease를 중복 처리하지 않음');
 perform pg_temp.check_true(public.account_has_external_media('11111111-1111-4111-8111-111111111111'),'lease 중에는 탈퇴 완료 불가');
 perform public.finish_media_cleanup(claimed_id,false);
 perform pg_temp.check_true(public.account_has_external_media('11111111-1111-4111-8111-111111111111'),'실패 후 실제 파일 잔존 검사 유지');
 perform pg_temp.check_true(public.claim_account_media_cleanup('11111111-1111-4111-8111-111111111111',100)='[]','실패 backoff를 우회하지 않음');
 update media_private.cleanup set not_before=now()-interval '1 second' where id=claimed_id;
 jobs:=public.claim_account_media_cleanup('11111111-1111-4111-8111-111111111111',100);
 perform pg_temp.check_true(jsonb_array_length(jobs)=1,'실패 파일 재시도');
 perform public.finish_media_cleanup(claimed_id,true);
 perform pg_temp.check_true(not public.account_has_external_media('11111111-1111-4111-8111-111111111111'),'파일 삭제 확인 후에만 탈퇴 허용');
 perform pg_temp.check_true((select state='deleted' from media_private.objects where id='10000000-0000-4000-8000-000000000001'),'물리 정리 후 삭제 완료');
end;
$$;
select pg_temp.check_true((select state='pending' from media_private.objects where id='20000000-0000-4000-8000-000000000001'),'계정별 정리는 타인의 pending 업로드를 건드리지 않음');
select pg_temp.check_true(exists(select 1 from media_private.cleanup where media_id='10000000-0000-4000-8000-000000000003' and lease_until is null),'타인의 정리 작업 lease를 점유하지 않음');
select pg_temp.check_true(public.resolve_media_locations_v2('[{"bucket":"event-images","path":"retired-source.jpg"}]')->0->>'provider'='supabase','은퇴한 저장소를 읽기 provider로 복구하지 않음');

do $$begin
 begin
  perform public.claim_account_media_cleanup(null,100);
  raise exception 'NULL 사용자로 전역 큐 접근';
 exception when insufficient_privilege then null; end;
 begin
  perform public.claim_account_media_cleanup('22222222-2222-4222-8222-222222222222',100);
  raise exception '삭제 fence 없는 계정 접근';
 exception when insufficient_privilege then null; end;
end$$;
select pg_temp.check_true(not has_function_privilege('anon','public.claim_account_media_cleanup(uuid,integer)','execute'),'익명은 삭제 claim 금지');
select pg_temp.check_true(not has_function_privilege('authenticated','public.claim_account_media_cleanup(uuid,integer)','execute'),'사용자는 서버 삭제 claim 직접 호출 금지');
select pg_temp.check_true(not has_function_privilege('authenticated','media_private.claim_cleanup(uuid,integer,uuid)','execute'),'내부 helper 직접 접근 금지');
select pg_temp.check_true(has_function_privilege('service_role','public.claim_account_media_cleanup(uuid,integer)','execute'),'서버 role만 계정 정리');
rollback;
