begin;

do $$
declare item jsonb;
declare targets jsonb;
declare photo_id uuid;
declare source_path constant text := 'cleanup-regression.jpg';
declare owner constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
begin
    assert not exists(select 1 from pg_trigger where tgname = 'media_legacy_object_deleted'),
        'Supabase 사본 삭제는 R2 논리 삭제를 호출하지 않음';
    assert not has_table_privilege('anon', 'media_private.buckets', 'select');
    assert not has_table_privilege('authenticated', 'media_private.buckets', 'update');

    insert into media_private.objects(bucket,path,state,byte_size,content_type,checksum)
    values ('event-images',source_path,'ready',100,'image/jpeg',repeat('a',64)) returning id into photo_id;
    insert into media_private.locations(media_id,provider,bucket,path,verified)
    values (photo_id,'supabase','event-images',source_path,true),
           (photo_id,'r2','r2-public','event-images/' || source_path,true);
    insert into storage.objects(bucket_id,name) values ('event-images',source_path);
    -- This isolated fixture models the metadata deletion performed by Storage API.
    delete from storage.objects where bucket_id='event-images' and name=source_path;
    assert (select state='ready' from media_private.objects where id=photo_id), 'R2 사진 상태 유지';
    assert not exists(select 1 from media_private.cleanup where media_id=photo_id), 'R2 정리 작업 생성 금지';

    delete from storage.buckets where id in (select id from media_private.buckets);
    assert (select count(*)=6 from media_private.buckets), '물리 버킷 삭제 후 논리 설정 보존';
    perform set_config('request.jwt.claim.role','service_role',true);
    item := public.prepare_service_media_v2('event-images','r2-only-service.jpg','image/jpeg',100);
    assert item->>'provider'='r2' and item->'required_providers'='[]', '버킷 없이 서버 업로드 준비';
    begin
        perform public.prepare_service_media_v2('event-images','too-large.jpg','image/jpeg',5242881);
        raise exception '용량 제한을 우회함';
    exception when raise_exception then
        if sqlerrm <> 'Invalid media upload' then raise; end if;
    end;

    insert into auth.users values(owner) on conflict do nothing;
    perform set_config('request.jwt.claim.sub',owner::text,true);
    perform set_config('request.jwt.claim.role','authenticated',true);
    item := public.prepare_media_upload_v2('profile-avatars',owner::text || '/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg','image/jpeg',100);
    assert item->>'provider'='r2' and item->'required_providers'='[]', '버킷 없이 사용자 업로드 준비';
    begin
        perform public.prepare_media_upload_v2('profile-avatars',owner::text || '/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg','image/webp',100);
        raise exception '기존 MIME 제한을 우회함';
    exception when raise_exception then
        if sqlerrm <> 'Invalid media upload' then raise; end if;
    end;
    begin
        perform public.prepare_media_upload_v2('menu-snapshot-raw','raw.gz','application/gzip',100);
        raise exception '메뉴 원문을 사진 설정에 포함함';
    exception when raise_exception then
        if sqlerrm <> 'Invalid media upload' then raise; end if;
    end;
    perform set_config('request.jwt.claim.role','service_role',true);
    perform public.register_media_targets_v2((item->>'id')::uuid,'[{"provider":"r2","bucket":"r2-private","pending_bucket":"r2-private"}]');
    perform public.begin_media_finalization((item->>'id')::uuid);
    targets := jsonb_build_array(jsonb_build_object('provider','r2','bucket','r2-private','path',(item->>'bucket')||'/'||(item->>'path'),'etag','new-r2'));
    perform public.complete_media_upload_v2((item->>'id')::uuid,targets,100,'image/jpeg',repeat('a',64));
    assert (select state='ready' from media_private.objects where id=(item->>'id')::uuid), 'Supabase 없이 R2 업로드 확정';
    perform set_config('request.jwt.claim.role','authenticated',true);
    assert public.resolve_media_locations_v2(jsonb_build_array(jsonb_build_object('bucket',item->>'bucket','path',item->>'path')))->0->>'provider'='r2';
    perform media_private.queue_delete((item->>'id')::uuid);
    assert exists(select 1 from media_private.cleanup where media_id=(item->>'id')::uuid and provider='r2'),
        '사용자의 실제 사진 삭제는 기존 R2 정리 경로를 유지';
end;
$$;

rollback;
