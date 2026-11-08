begin;

do $$
declare owner constant uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
declare source constant text := owner::text || '/photo.jpg';
declare destination constant text := 'withdrawn/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/1.jpg';
declare attempt jsonb;
declare copy_id uuid;
declare job_id bigint;
begin
    assert not (select legacy_required from media_private.settings), '새 업로드의 Supabase 호환 복사를 중단';
    assert not has_function_privilege('anon', 'public.reserve_withdrawn_review_photo(uuid,text,text,text)', 'execute');
    assert not has_function_privilege('authenticated', 'public.finish_withdrawn_review_photo(uuid,uuid,timestamptz,text,text)', 'execute');
    perform set_config('request.jwt.claim.role','service_role',true);

    begin
        perform public.reserve_withdrawn_review_photo(owner,source,'wrong.jpg','private');
        raise exception '탈퇴 리뷰와 무관한 목적지를 허용함';
    exception when insufficient_privilege then null;
    end;

    attempt := public.reserve_withdrawn_review_photo(owner,source,destination,'private');
    copy_id := (attempt->>'id')::uuid;
    assert attempt->>'state' = 'pending' and attempt->>'owner_id' is null;
    assert exists(select 1 from public.list_account_review_photo_copies(owner)), '예약만으로 완료 처리하지 않음';
    assert (public.reserve_withdrawn_review_photo(owner,source,destination,'private')->>'id')::uuid = copy_id;
    begin
        perform public.finish_withdrawn_review_photo(owner,copy_id,(attempt->>'upload_expires_at')::timestamptz,'wrong',repeat('b',64));
        raise exception '잘못된 체크섬으로 확정함';
    exception when raise_exception then
        if sqlerrm <> 'Withdrawn review copy verification failed' then raise; end if;
    end;

    update media_private.objects set upload_expires_at = now() - interval '1 hour' where id = copy_id;
    select (j->>'id')::bigint into strict job_id from jsonb_array_elements(public.claim_media_cleanup(copy_id,10)) j;
    assert (select state from media_private.objects where id=copy_id)='deleting';
    perform public.finish_media_cleanup(job_id,true);
    assert (select state from media_private.objects where id=copy_id)='deleted';
    attempt := public.reserve_withdrawn_review_photo(owner,source,destination,'private');
    assert attempt->>'state' = 'pending', '만료 정리 후 안전하게 재시도';
    begin
        perform public.finish_withdrawn_review_photo(owner,copy_id,now() - interval '1 hour','stale',repeat('a',64));
        raise exception '만료된 복사 요청을 확정함';
    exception when raise_exception then
        if sqlerrm <> 'Withdrawn review copy reservation expired' then raise; end if;
    end;

    perform public.finish_withdrawn_review_photo(owner,copy_id,(attempt->>'upload_expires_at')::timestamptz,'destination',repeat('a',64));
    perform public.finish_withdrawn_review_photo(owner,copy_id,(attempt->>'upload_expires_at')::timestamptz,'destination',repeat('a',64));
    assert not exists(select 1 from public.list_account_review_photo_copies(owner)), '검증된 R2 사진만 탈퇴 보존 완료로 처리';
    assert exists(select 1 from media_private.locations l where l.media_id=copy_id and l.provider='r2' and l.verified and not l.deleted);
    assert not exists(select 1 from storage.objects where bucket_id='shop-review-images' and name=destination), 'Supabase에 호환 사본을 생성하지 않음';
end;
$$;
rollback;
