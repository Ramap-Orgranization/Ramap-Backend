\set ON_ERROR_STOP on
begin;
create function pg_temp.check_true(value boolean,label text) returns void language plpgsql as $$begin
 if value is distinct from true then raise exception 'FAIL: %',label; end if; end$$;
insert into auth.users values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
select set_config('request.jwt.claim.role','service_role',false);
select public.configure_media_storage(true,true,true);
select set_config('request.jwt.claim.role','authenticated',false);

do $$declare upload jsonb;begin
 upload:=public.prepare_media_upload('shop-review-images','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','image/jpeg',100);
 perform pg_temp.check_true(upload->>'state'='pending','업로드는 검증 전 pending');
 perform pg_temp.check_true(media_private.lock_available('shop-review-images',upload->>'path') is null,'미확정 사진은 리뷰에 연결 불가');
 perform pg_temp.check_true(jsonb_array_length(public.resolve_media_locations(jsonb_build_array(jsonb_build_object('bucket','shop-review-images','path',upload->>'path'))))=0,'미확정 사진 읽기 차단');
 begin
  perform public.prepare_media_upload('shop-review-images','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','image/jpeg',100);
  raise exception '타인 경로 업로드를 허용함';
 exception when insufficient_privilege then null; end;
 begin
  perform public.prepare_media_upload('news-report-evidence','cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','image/jpeg',100);
  raise exception '비관리자 증거 업로드를 허용함';
 exception when insufficient_privilege then null; end;
end$$;

select set_config('request.jwt.claim.role','service_role',false);
do $$declare item media_private.objects;begin
 select * into item from media_private.objects limit 1;
 perform public.register_media_upload_target(item.id,'test-private','test-private');
 begin
  perform public.complete_media_upload(item.id,'test-private',item.bucket||'/'||item.path,'1',100,'image/jpeg',repeat('a',64));
  raise exception '구버전 복사 없이 ready 전환';
 exception when raise_exception then
  if sqlerrm<>'Legacy mirror missing' then raise; end if;
 end;
 insert into storage.objects(bucket_id,name,owner,owner_id,metadata) values(item.bucket,item.path,item.owner_id,item.owner_id::text,'{"size":100,"mimetype":"image/jpeg"}');
 perform public.complete_media_upload(item.id,'test-private',item.bucket||'/'||item.path,'1',100,'image/jpeg',repeat('a',64));
 perform public.complete_media_upload(item.id,'test-private',item.bucket||'/'||item.path,'1',100,'image/jpeg',repeat('a',64));
 perform pg_temp.check_true(media_private.lock_available(item.bucket,item.path)=item.id,'검증한 사진 연결과 완료 재시도');
end$$;

select set_config('request.jwt.claim.role','authenticated',false);
select pg_temp.check_true((public.resolve_media_locations('[{"bucket":"shop-review-images","path":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg"}]')->0->>'provider')='gcs','소유자 Firebase 위치 반환');
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
select pg_temp.check_true(public.resolve_media_locations('[{"bucket":"shop-review-images","path":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg"}]')='[]','비공개 타인 사진 거절');
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
insert into public.community_reports values(array['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg'],null);
do $$begin
 begin
  perform public.delete_media_object('shop-review-images','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg');
  raise exception '신고 증거 사진을 삭제함';
 exception when insufficient_privilege then null; end;
end$$;
delete from public.community_reports;
select public.delete_media_object('shop-review-images','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg');
select pg_temp.check_true(public.resolve_media_locations('[{"bucket":"shop-review-images","path":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg"}]')='[]','삭제 중 legacy 사진으로 우회하지 않음');
select set_config('request.jwt.claim.role','service_role',false);
do $$declare jobs jsonb; job jsonb;begin
 jobs:=public.claim_media_cleanup();
 perform pg_temp.check_true(jsonb_array_length(jobs)=2,'두 저장소 삭제 작업 생성');
 perform pg_temp.check_true(public.claim_media_cleanup()='[]','lease 중인 작업 중복 실행 차단');
 for job in select value from jsonb_array_elements(jobs) loop perform public.finish_media_cleanup((job->>'id')::bigint,true); end loop;
 perform pg_temp.check_true((select state='deleted' from media_private.objects limit 1),'물리 복사본 삭제 완료');
 begin
  perform public.record_media_copy('shop-review-images','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','test-private','shop-review-images/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','1',repeat('a',64),100,(select updated_at from storage.objects limit 1));
  raise exception '백필이 삭제 사진을 부활시킴';
 exception when raise_exception then
  if sqlerrm<>'Copy identity changed' then raise; end if;
 end;
end$$;
select pg_temp.check_true(not has_function_privilege('anon','public.complete_media_upload(uuid,text,text,text,bigint,text,text)','execute'),'완료 RPC 익명 호출 차단');
select pg_temp.check_true(not has_table_privilege('authenticated','media_private.objects','insert'),'클라이언트가 ready를 직접 설정하지 못함');
select pg_temp.check_true(not has_function_privilege('anon','public.prepare_media_upload(text,text,text,bigint)','execute'),'직접 default grant가 있어도 익명 업로드 RPC 차단');
select pg_temp.check_true(not has_function_privilege('authenticated','media_private.queue_delete(uuid)','execute'),'내부 삭제 helper 직접 호출 차단');
insert into storage.objects(bucket_id,name,metadata) values('event-images','legacy-empty.jpg','{"size":0,"mimetype":"image/jpeg"}');
select public.record_media_copy('event-images','legacy-empty.jpg','test-public','event-images/legacy-empty.jpg','2',repeat('b',64),0,now());
select pg_temp.check_true((select byte_size=0 and state='ready' from media_private.objects where path='legacy-empty.jpg'),'기존 빈 파일을 원본 그대로 보존');
do $$begin
 begin
  perform public.prepare_service_media('event-images','new-empty.jpg','image/jpeg',0);
  raise exception '새 빈 파일 업로드를 허용함';
 exception when raise_exception then
  if sqlerrm<>'Invalid media upload' then raise; end if;
 end;
end$$;
rollback;
