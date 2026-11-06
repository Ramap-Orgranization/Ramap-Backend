do $$
begin
    if has_function_privilege('anon','public.fetch_my_review_count()','execute') then
        raise exception '비회원에게 개수 조회를 허용했습니다';
    end if;
    if has_table_privilege('authenticated','public.shop_reviews','select') then
        raise exception '리뷰 테이블 직접 조회 권한을 추가하면 안 됩니다';
    end if;
end;
$$;

set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
do $$
begin
    if public.fetch_my_review_count() <> 4 then
        raise exception '공개·비공개·검수 상태를 포함한 본인 리뷰 수가 다릅니다';
    end if;
    if pg_typeof(public.fetch_my_review_count()) <> 'integer'::regtype then
        raise exception '개수만 반환해야 합니다';
    end if;
end;
$$;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
do $$
begin
    if public.fetch_my_review_count() <> 1 then
        raise exception '다른 계정의 리뷰가 합산되었습니다';
    end if;
end;
$$;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
do $$
begin
    if public.fetch_my_review_count() <> 0 then
        raise exception '리뷰가 없으면 0을 반환해야 합니다';
    end if;
end;
$$;

select set_config('request.jwt.claim.sub','',false);
do $$
begin
    perform public.fetch_my_review_count();
    raise exception '세션이 없는 요청을 허용했습니다';
exception when insufficient_privilege then null;
end;
$$;

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
do $$
begin
    perform public.fetch_my_review_count();
    raise exception '존재하지 않는 계정을 허용했습니다';
exception when insufficient_privilege then null;
end;
$$;

reset role;
insert into public.account_deletion_requests values ('00000000-0000-0000-0000-000000000001');
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
do $$
begin
    perform public.fetch_my_review_count();
    raise exception '탈퇴 중인 계정을 허용했습니다';
exception when insufficient_privilege then null;
end;
$$;
reset role;
