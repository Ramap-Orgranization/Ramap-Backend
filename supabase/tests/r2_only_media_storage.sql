\set ON_ERROR_STOP on
begin;
create function pg_temp.check_true(value boolean,label text) returns void language plpgsql as $$begin
 if value is distinct from true then raise exception 'FAIL: %',label; end if; end$$;
select pg_temp.check_true((select deleted from media_private.locations where media_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd' and provider='gcs'),'기존 위치는 이력만 보존');
select pg_temp.check_true(exists(select 1 from storage.objects where name='retired-source.jpg'),'기존 원본을 삭제하지 않음');
select set_config('request.jwt.claim.role','service_role',false);
select public.configure_r2_media(true,true);
insert into auth.users values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
select set_config('request.jwt.claim.role','authenticated',false);
do $$declare item jsonb; images jsonb; targets jsonb;begin
 item:=public.prepare_media_upload_v2('profile-avatars','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','image/jpeg',100);
 perform pg_temp.check_true(item->>'provider'='r2' and item->'required_providers'='["supabase"]','R2 업로드에는 Supabase 호환 복사만 필요');
 perform pg_temp.check_true(public.prepare_media_upload('profile-avatars','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg','image/jpeg',100)->>'provider'='supabase','v1은 Supabase 업로드로 유지');
 perform set_config('request.jwt.claim.role','service_role',false);
 perform public.register_media_targets_v2((item->>'id')::uuid,'[{"provider":"r2","bucket":"r2-private","pending_bucket":"r2-private"}]');
 perform public.begin_media_finalization((item->>'id')::uuid);
 targets:=jsonb_build_array(jsonb_build_object('provider','r2','bucket','r2-private','path',(item->>'bucket')||'/'||(item->>'path'),'etag','opaque'));
 begin
  perform public.complete_media_upload_v2((item->>'id')::uuid,targets,100,'image/jpeg',repeat('a',64));
  raise exception 'Supabase 복사 없이 확정';
 exception when raise_exception then if sqlerrm<>'Legacy mirror missing' then raise; end if; end;
 insert into storage.objects(bucket_id,name,owner,owner_id,metadata) values(item->>'bucket',item->>'path','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','{"size":100,"mimetype":"image/jpeg"}');
 perform public.complete_media_upload_v2((item->>'id')::uuid,targets,100,'image/jpeg',repeat('a',64));
 images:=jsonb_build_array(jsonb_build_object('bucket',item->>'bucket','path',item->>'path'));
 perform set_config('request.jwt.claim.role','authenticated',false);
 perform pg_temp.check_true(public.resolve_media_locations(images)->0->>'provider'='supabase','v1 읽기는 Supabase');
 perform pg_temp.check_true(public.resolve_media_locations_v2(images)->0->>'provider'='r2','v2 읽기는 R2');
 perform set_config('request.jwt.claim.role','service_role',false);
 perform public.configure_r2_media(false,false);
 perform pg_temp.check_true(public.resolve_media_locations_v2(images)->0->>'provider'='supabase','R2를 끄면 Supabase로 복구');
end$$;
select pg_temp.check_true(not has_function_privilege('service_role','public.register_media_upload_target(uuid,text,text)','execute'),'이전 저장소 서명 대상 RPC 차단');
select pg_temp.check_true(not has_function_privilege('service_role','public.record_media_copy(text,text,text,text,text,text,bigint,timestamptz)','execute'),'이전 복사 writer RPC 차단');
-- The same preflight used by the migration refuses orphaning old-only files.
insert into media_private.objects(id,bucket,path,state,byte_size,content_type)
 values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','event-images','only-old.jpg','ready',100,'image/jpeg');
insert into media_private.locations(media_id,provider,bucket,path,generation,verified)
 values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','gcs','old-public','event-images/only-old.jpg','1',true);
do $$begin
 begin
  perform media_private.assert_media_retirement_safe();
  raise exception '유일한 복사본을 보지 않고 이전함';
 exception when raise_exception then if sqlerrm<>'Copy photos to supported storage before retiring the old location' then raise; end if; end;
end$$;
rollback;
