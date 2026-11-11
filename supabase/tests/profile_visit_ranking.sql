begin;

insert into auth.users values
    ('00000000-0000-0000-0000-000000000001'),
    ('00000000-0000-0000-0000-000000000002'),
    ('00000000-0000-0000-0000-000000000003');

insert into public.public_profiles(user_id, nickname, is_public) values
    ('00000000-0000-0000-0000-000000000001', 'Author', true),
    ('00000000-0000-0000-0000-000000000002', 'Viewer', true),
    ('00000000-0000-0000-0000-000000000003', 'Empty', true);

insert into public.ramen_shops(id, name, is_visible, instagram_profile_image_path)
select ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid,
       case when n = 1 then 'Alpha' when n in (2, 3) then 'Beta' else 'Shop ' || lpad(n::text, 2, '0') end,
       n <= 11,
       case n when 1 then 'alpha/profile.jpg' when 12 then 'hidden/profile.jpg' end
from generate_series(1, 12) as n;

insert into public.shop_reviews(user_id, shop_id, is_public, moderation_status)
select '00000000-0000-0000-0000-000000000001', id, true, 'published'
from public.ramen_shops;

insert into public.shop_reviews(user_id, shop_id, is_public, moderation_status) values
    ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0001-000000000001', true, 'published'),
    ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0001-000000000001', true, 'published'),
    ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0001-000000000001', false, 'published'),
    ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0001-000000000001', true, 'pending'),
    ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0001-000000000001', true, 'published');

insert into public.shop_reviews(user_id, shop_id, is_public, moderation_status)
select '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0001-000000000012', true, 'published'
from generate_series(1, 15);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$
declare
    result jsonb := public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001');
begin
    if result ->> 'available' is distinct from 'true'
       or result #>> '{shops,0,visit_count}' is distinct from '5'
       or jsonb_array_length(result -> 'shops') is distinct from 10 then
        raise exception '본인의 비공개·검수 리뷰를 포함한 매장별 방문 순위와 최대 10개 제한이 필요합니다';
    end if;
    if result #>> '{shops,0,shop_name}' is distinct from 'Alpha'
       or result #>> '{shops,1,shop_id}' is distinct from '00000000-0000-0000-0001-000000000002'
       or result #>> '{shops,2,shop_id}' is distinct from '00000000-0000-0000-0001-000000000003'
       or result #>> '{shops,9,shop_name}' is distinct from 'Shop 10' then
        raise exception '비공개 매장은 제외하고 동률은 이름과 ID 순으로 정렬해야 합니다';
    end if;
    if result #>> '{shops,0,instagram_profile_image_path}' is distinct from 'alpha/profile.jpg'
       or result #> '{shops,1,instagram_profile_image_path}' is distinct from 'null'::jsonb
       or result::text like '%hidden/profile.jpg%' then
        raise exception '공개 매장의 사진 경로와 사진 없음만 반환하고 비공개 매장의 사진 경로는 숨겨야 합니다';
    end if;
end;
$$;

savepoint cutoff_tie;
reset role;
insert into public.shop_reviews(user_id, shop_id, is_public, moderation_status)
select '00000000-0000-0000-0000-000000000001',
       ('00000000-0000-0000-0001-' || lpad(shop_number::text, 12, '0'))::uuid,
       true,
       'published'
from generate_series(2, 9) as shop_number
cross join lateral generate_series(1, shop_number + 8);

set local role authenticated;
do $$
declare
    result jsonb := public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001');
begin
    if jsonb_array_length(result -> 'shops') is distinct from 10
       or result #>> '{shops,8,is_tied}' is distinct from 'false'
       or result #>> '{shops,9,shop_name}' is distinct from 'Shop 10'
       or result #>> '{shops,9,is_tied}' is distinct from 'true' then
        raise exception '10번째 매장은 응답에서 제외된 11번째 매장과 동률인 경우에도 동률로 표시해야 합니다';
    end if;
end;
$$;
rollback to savepoint cutoff_tie;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$
declare
    result jsonb := public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001');
begin
    if result #>> '{shops,0,visit_count}' is distinct from '3'
       or result #>> '{shops,0,instagram_profile_image_path}' is distinct from 'alpha/profile.jpg' then
        raise exception '타인은 해당 작성자의 공개·게시 리뷰만 집계해야 합니다';
    end if;
    if public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000003')
       is distinct from '{"available":true,"shops":[]}'::jsonb then
        raise exception '조회 가능한 빈 순위는 접근 불가와 구분해야 합니다';
    end if;
end;
$$;

set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$
begin
    if public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001') #>> '{shops,0,visit_count}' is distinct from '3' then
        raise exception '비회원은 공개 프로필의 공개·게시 리뷰 집계를 볼 수 있어야 합니다';
    end if;
end;
$$;

reset role;
update public.public_profiles set is_public = false where user_id = '00000000-0000-0000-0000-000000000001';
insert into public.profile_follows(follower_id, followed_id, status) values
    ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'pending');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
do $$
begin
    if public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001')
       is distinct from '{"available":false,"shops":[]}'::jsonb then
        raise exception '승인 대기 팔로워에게 비공개 프로필 순위를 노출하면 안 됩니다';
    end if;
end;
$$;

reset role;
update public.profile_follows set status = 'following';
set local role authenticated;
do $$
begin
    if public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001') #>> '{shops,0,visit_count}' is distinct from '3' then
        raise exception '승인 팔로워는 공개·게시 리뷰 집계만 볼 수 있어야 합니다';
    end if;
end;
$$;

reset role;
update public.public_profiles set followers_can_read_reviews = false
where user_id = '00000000-0000-0000-0000-000000000001';
set local role authenticated;
do $$
begin
    if public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001')
       is distinct from '{"available":false,"shops":[]}'::jsonb then
        raise exception '팔로워 리뷰 읽기 설정이 꺼지면 순위를 숨겨야 합니다';
    end if;
end;
$$;

reset role;
update public.public_profiles set is_public = true where user_id = '00000000-0000-0000-0000-000000000001';
insert into public.user_blocks values ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001');
set local role authenticated;
do $$
begin
    if public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001')
       is distinct from '{"available":false,"shops":[]}'::jsonb then
        raise exception '차단한 프로필의 순위를 노출하면 안 됩니다';
    end if;
end;
$$;

reset role;
delete from public.user_blocks;
insert into public.account_deletion_requests values ('00000000-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$
begin
    if public.fetch_profile_visit_ranking('00000000-0000-0000-0000-000000000001')
       is distinct from '{"available":false,"shops":[]}'::jsonb then
        raise exception '탈퇴 요청 이후 남은 세션에도 순위를 노출하면 안 됩니다';
    end if;
end;
$$;

reset role;
do $$
begin
    if has_function_privilege('service_role', 'public.fetch_profile_visit_ranking(uuid)', 'EXECUTE')
       or has_schema_privilege('authenticated', 'community_private', 'USAGE') then
        raise exception 'RPC 호출에 필요하지 않은 권한이 부여되었습니다';
    end if;
end;
$$;

rollback;
