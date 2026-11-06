\set ON_ERROR_STOP on
begin;
create function pg_temp.check_true(value boolean,label text) returns void language plpgsql as $$begin
 if value is distinct from true then raise exception 'FAIL: %',label; end if; end$$;
insert into auth.users values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
select set_config('request.jwt.claim.role','service_role',false);
select public.configure_media_storage(true,true,true);
select public.configure_r2_media(true,true);
select set_config('request.jwt.claim.role','authenticated',false);
do $$declare item jsonb; targets jsonb; locations jsonb; images jsonb;begin
 item:=public.prepare_media_upload_v2('shop-review-images','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','image/jpeg',100);
 perform pg_temp.check_true(item->>'provider'='r2','v2 업로드는 R2를 선택');
 perform pg_temp.check_true(item->'required_providers' @> '["gcs","supabase"]','GCS와 Supabase 호환 복사를 저장');
 images:=jsonb_build_array(jsonb_build_object('bucket',item->>'bucket','path',item->>'path'));
 perform pg_temp.check_true(public.resolve_media_locations_v2(images)='[]','미확정 R2 사진은 읽을 수 없음');
 perform set_config('request.jwt.claim.role','service_role',false);
 perform public.register_media_targets_v2((item->>'id')::uuid,'[{"provider":"r2","bucket":"r2-private","pending_bucket":"r2-private"},{"provider":"gcs","bucket":"gcs-private","pending_bucket":"gcs-private"}]');
 perform public.begin_media_finalization((item->>'id')::uuid);
 perform public.configure_media_storage(true,true,false);
 perform public.configure_r2_media(false,false);
 perform pg_temp.check_true((public.fetch_service_media((item->>'id')::uuid)->>'legacy_required')::boolean,'설정 변경이 진행 중인 업로드의 복사 요구를 바꾸지 않음');
 locations:=jsonb_build_array(jsonb_build_object('provider','r2','bucket','r2-private','path',(item->>'bucket')||'/'||(item->>'path'),'etag','opaque-r2-etag'));
 begin
  perform public.complete_media_upload_v2((item->>'id')::uuid,locations,100,'image/jpeg',repeat('a',64));
  raise exception '미완성 복사를 ready로 허용함';
 exception when raise_exception then
  if sqlerrm not in ('Legacy mirror missing','Required mirror missing') then raise; end if;
 end;
 insert into storage.objects(bucket_id,name,owner,owner_id,metadata) values(item->>'bucket',item->>'path','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','{"size":100,"mimetype":"image/jpeg"}');
 locations:=locations||jsonb_build_array(jsonb_build_object('provider','gcs','bucket','gcs-private','path',(item->>'bucket')||'/'||(item->>'path'),'generation','123'));
 perform public.complete_media_upload_v2((item->>'id')::uuid,locations,100,'image/jpeg',repeat('a',64));
 perform public.configure_r2_media(true,true);
 perform set_config('request.jwt.claim.role','authenticated',false);
 perform pg_temp.check_true(public.resolve_media_locations(images)->0->>'provider'='gcs','v1에는 R2가 반환되지 않음');
 perform pg_temp.check_true(public.resolve_media_locations_v2(images)->0->>'provider'='r2','v2에는 검증된 R2 복사본을 우선 반환');
 perform set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
 perform pg_temp.check_true(public.resolve_media_locations_v2(images)='[]','R2에서도 비공개 타인 사진 거절');
 perform set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
 perform pg_temp.check_true((select generation is null and etag='opaque-r2-etag' from media_private.locations where media_id=(item->>'id')::uuid and provider='r2'),'ETag와 GCS generation 분리');
end$$;

-- Deletion during finalize leaves tracked destinations behind the expiry/lease fence.
select set_config('request.jwt.claim.role','authenticated',false);
do $$declare item jsonb;begin
 item:=public.prepare_media_upload_v2('profile-avatars','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/dddddddd-dddd-4ddd-8ddd-dddddddddddd.jpg','image/jpeg',100);
 perform set_config('request.jwt.claim.role','service_role',false);
 perform public.register_media_targets_v2((item->>'id')::uuid,'[{"provider":"r2","bucket":"r2-private","pending_bucket":"r2-private"},{"provider":"gcs","bucket":"gcs-private","pending_bucket":"gcs-private"}]');
 perform public.begin_media_finalization((item->>'id')::uuid);
 perform set_config('request.jwt.claim.role','authenticated',false);
 perform public.delete_media_object(item->>'bucket',item->>'path');
 perform set_config('request.jwt.claim.role','service_role',false);
 perform pg_temp.check_true(public.claim_media_cleanup((item->>'id')::uuid)='[]','유효한 PUT과 진행 중 확정 이후까지 삭제를 유예');
 perform pg_temp.check_true(public.account_has_external_media('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'미확정 R2 복사와 삭제 작업이 남으면 탈퇴 완료 차단');
 begin
  perform public.begin_media_finalization((item->>'id')::uuid);
  raise exception '삭제된 사진 확정을 다시 허용함';
 exception when raise_exception then if sqlerrm<>'Upload unavailable' then raise; end if; end;
end$$;
select set_config('request.jwt.claim.role','service_role',false);
-- v1 public writers mirror R2 before CDN cutover; v1 private writers stay compatible.
select pg_temp.check_true(public.prepare_service_media('event-images','v1-public.jpg','image/jpeg',100)->'required_providers' @> '["r2"]','구형 공개 업로드도 R2에 복사');
-- Registry-only GCS photos must not disappear from inventory.
insert into media_private.objects(id,bucket,path,state,byte_size,content_type,checksum)
 values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','event-images','gcs-only.jpg','ready',100,'image/jpeg',repeat('b',64));
insert into media_private.locations(media_id,provider,bucket,path,generation,verified)
 values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','gcs','gcs-public','event-images/gcs-only.jpg','3',true);
select pg_temp.check_true(exists(select 1 from jsonb_array_elements(public.media_inventory_v2()) row where row->>'path'='gcs-only.jpg'),'GCS 전용 사진도 백필 inventory에 포함');
select public.register_media_copy_target_v2('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','r2','r2-public');
select public.record_media_copy_v2('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','{"provider":"gcs","bucket":"gcs-public","path":"event-images/gcs-only.jpg","generation":"3"}',
 '{"provider":"r2","bucket":"r2-public","path":"event-images/gcs-only.jpg","etag":"etag"}',repeat('b',64),100,'image/jpeg');
select public.delete_service_media('event-images','gcs-only.jpg');
do $$begin
 begin
  perform public.record_media_copy_v2('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','{"provider":"gcs","bucket":"gcs-public","path":"event-images/gcs-only.jpg","generation":"3"}',
   '{"provider":"r2","bucket":"r2-public","path":"event-images/gcs-only.jpg","etag":"etag"}',repeat('b',64),100,'image/jpeg');
  raise exception '백필로 삭제 사진을 부활시킴';
 exception when raise_exception then if sqlerrm<>'Copy identity changed' then raise; end if; end;
end$$;
select pg_temp.check_true(not has_function_privilege('authenticated','public.configure_r2_media(boolean,boolean)','execute'),'사용자가 저장소 설정을 바꿀 수 없음');
select pg_temp.check_true(not has_function_privilege('anon','public.complete_media_upload_v2(uuid,jsonb,bigint,text,text)','execute'),'익명 R2 완료 호출 차단');
select pg_temp.check_true(not has_function_privilege('authenticated','media_private.prepare_upload(text,text,text,bigint,boolean)','execute'),'내부 업로드 helper 호출 차단');
rollback;
