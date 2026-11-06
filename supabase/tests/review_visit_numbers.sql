-- Run only against the disposable fixture using review_visit_numbers_test.py.
begin;

create function pg_temp.assert_visit(p_id uuid, p_expected integer) returns void
language plpgsql as $$
declare
    review public.shop_reviews;
    page jsonb;
begin
    select * into strict review from public.shop_reviews where id = p_id;
    perform set_config('request.jwt.claim.sub', review.user_id::text, true);
    assert (community_private.review_mutation_snapshot(p_id)->>'visit_number')::int = p_expected,
        '작성·수정 응답은 남은 방문 기록을 센다';
    assert (public.fetch_my_review(p_id)->>'visit_number')::int = p_expected,
        '내 리뷰 상세는 남은 방문 기록을 센다';
    assert (select visit_number from public.fetch_shop_reviews(review.shop_id) where id = p_id) = p_expected,
        '매장 목록은 남은 방문 기록을 센다';
    assert (select visit_number from public.fetch_profile_reviews(review.user_id) where id = p_id) = p_expected,
        '프로필 목록은 남은 방문 기록을 센다';
    page := public.fetch_my_reviews();
    assert (select (r->>'visit_number')::int from jsonb_array_elements(page->'reviews') r where r->>'id' = p_id::text) = p_expected,
        '내 리뷰 목록은 남은 방문 기록을 센다';
    page := public.fetch_shop_reviews_page(review.shop_id);
    assert (select (r->>'visit_number')::int from jsonb_array_elements(page->'reviews') r where r->>'id' = p_id::text) = p_expected,
        '매장 페이지는 남은 방문 기록을 센다';
    if review.is_public and review.moderation_status = 'published' then
        page := public.fetch_review_feed_page();
        assert (select (r->'review'->>'visit_number')::int from jsonb_array_elements(page->'reviews') r where r->'review'->>'id' = p_id::text) = p_expected,
            '최신 피드는 남은 방문 기록을 센다';
        page := public.fetch_popular_review_feed_page();
        assert (select (r->'review'->>'visit_number')::int from jsonb_array_elements(page->'reviews') r where r->'review'->>'id' = p_id::text) = p_expected,
            '인기 피드는 남은 방문 기록을 센다';
    end if;
end;
$$;

do $$
declare
    owner_id uuid := gen_random_uuid();
    viewer_id uuid := gen_random_uuid();
    shop_id uuid := gen_random_uuid();
    other_shop_id uuid := gen_random_uuid();
    first_id uuid;
    middle_id uuid;
    last_id uuid;
    other_id uuid;
    page jsonb;
    filter_name text;
    sort_name text;
begin
    insert into public.ramen_shops(id, name) values (shop_id, '방문 검증 매장'), (other_shop_id, '별도 매장');
    insert into public.public_profiles(user_id, nickname, is_public)
        values (owner_id, '방문 검증 작성자', true), (viewer_id, '다른 작성자', true);

    -- Regression: one remaining review with the historical ordinal six.
    insert into community_private.review_visit_counters values (owner_id, shop_id, 5);
    insert into public.shop_reviews(shop_id, user_id, body)
        values (shop_id, owner_id, '여섯 번째로 작성한 유일한 리뷰') returning id into first_id;
    assert (select visit_number from public.shop_reviews where id = first_id) = 6,
        '기존 누적 번호 6인 데이터를 재현한다';
    perform pg_temp.assert_visit(first_id, 1);

    for attempt in 1..6 loop
        delete from public.shop_reviews where id = first_id;
        insert into public.shop_reviews(shop_id, user_id, body)
            values (shop_id, owner_id, '삭제 후 다시 작성한 리뷰') returning id into first_id;
        perform pg_temp.assert_visit(first_id, 1);
    end loop;

    insert into public.shop_reviews(shop_id, user_id, body, is_public, created_at)
        values (shop_id, owner_id, '비공개 두 번째 방문', false, '2026-01-02') returning id into middle_id;
    insert into public.shop_reviews(shop_id, user_id, body, created_at)
        values (shop_id, owner_id, '공개 세 번째 방문', '2026-01-03') returning id into last_id;
    perform pg_temp.assert_visit(middle_id, 2);
    perform pg_temp.assert_visit(last_id, 3);
    assert (community_private.review_mutation_snapshot(last_id)->>'author_review_count')::int = 2,
        '작성자의 공개 리뷰 개수는 매장의 방문 차수와 별개다';

    insert into public.shop_reviews(shop_id, user_id, body)
        values (other_shop_id, owner_id, '다른 매장 첫 방문') returning id into other_id;
    perform pg_temp.assert_visit(other_id, 1);
    insert into public.shop_reviews(shop_id, user_id, body)
        values (shop_id, viewer_id, '다른 작성자의 첫 방문') returning id into other_id;
    perform pg_temp.assert_visit(other_id, 1);
    perform pg_temp.assert_visit(last_id, 3);

    update public.shop_reviews set body = '본문을 바꾼 첫 방문', is_public = false, moderation_status = 'rejected'
        where id = first_id;
    perform pg_temp.assert_visit(first_id, 1);
    perform pg_temp.assert_visit(last_id, 3);
    delete from public.shop_reviews where id = middle_id;
    perform pg_temp.assert_visit(last_id, 2);
    perform pg_temp.assert_visit(first_id, 1);
    delete from public.shop_reviews where id = first_id;
    perform pg_temp.assert_visit(last_id, 1);
    insert into public.shop_reviews(shop_id, user_id, body)
        values (shop_id, owner_id, '삭제 뒤의 두 번째 방문') returning id into middle_id;
    perform pg_temp.assert_visit(middle_id, 2);
    delete from public.shop_reviews where id = middle_id;
    perform pg_temp.assert_visit(last_id, 1);

    -- Blocked reveal, anonymous feed and visibility filters use the same visit number.
    insert into public.user_blocks values (viewer_id, owner_id);
    perform set_config('request.jwt.claim.sub', viewer_id::text, true);
    assert (public.fetch_blocked_shop_review_once(last_id)->>'visit_number')::int = 1,
        '차단 리뷰 일회 열람도 삭제된 방문을 제외한다';
    assert community_private.review_mutation_snapshot(last_id) is null, '타인의 작성 응답은 볼 수 없다';
    assert public.fetch_my_review(last_id) is null, '타인의 내 리뷰 상세는 볼 수 없다';
    insert into public.user_shop_bookmarks values (viewer_id, shop_id);
    insert into public.profile_follows values (viewer_id, owner_id, 'following');
    foreach filter_name in array array['saved_shops', 'following'] loop
        foreach sort_name in array array['latest', 'popular'] loop
            page := public.fetch_filtered_review_feed_page_v2(filter_name, sort_name);
            assert (select (r->'review'->>'visit_number')::int from jsonb_array_elements(page->'reviews') r
                where r->'review'->>'id' = last_id::text) = 1,
                '저장한 매장과 팔로잉 피드도 정렬에 관계없이 같은 방문 차수를 반환한다';
        end loop;
    end loop;
    perform set_config('request.jwt.claim.sub', '', true);
    page := public.fetch_review_feed_page();
    assert (select (r->'review'->>'visit_number')::int from jsonb_array_elements(page->'reviews') r
        where r->'review'->>'id' = last_id::text) = 1, '비로그인 피드도 같은 차수를 반환한다';
    update public.shop_reviews set is_public = false where id = last_id;
    assert not exists(select 1 from public.fetch_shop_reviews(shop_id) where id = last_id),
        '방문 계산 변경으로 비공개 리뷰가 노출되지 않는다';
    assert not exists(select 1 from public.fetch_profile_reviews(owner_id) where id = last_id),
        '프로필 비공개 리뷰도 노출되지 않는다';

    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    insert into public.shop_reviews(shop_id, user_id, body)
        values (shop_id, owner_id, '비공개 방문 이후 공개 리뷰') returning id into middle_id;
    page := public.fetch_my_reviews(0, 'public');
    assert (select (r->>'visit_number')::int from jsonb_array_elements(page->'reviews') r
        where r->>'id' = middle_id::text) = 2, '공개 필터는 비공개 방문을 차수에서 제외하지 않는다';
    perform pg_temp.assert_visit(middle_id, 2);
end;
$$;

do $$
declare
    owner_id uuid := gen_random_uuid();
    shop_id uuid := gen_random_uuid();
    review_id uuid;
    page jsonb;
begin
    insert into public.ramen_shops(id, name) values (shop_id, '페이지 방문 검증');
    insert into public.public_profiles(user_id, nickname, is_public) values (owner_id, '페이지 검증', true);
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    for visit in 1..12 loop
        insert into public.shop_reviews(shop_id, user_id, body, created_at)
            values (shop_id, owner_id, '페이지 순서 검증', '2026-06-01'::timestamptz + visit * interval '1 day');
    end loop;
    delete from public.shop_reviews where user_id = owner_id and visit_number in (1, 3);
    select id into review_id from public.shop_reviews where user_id = owner_id and visit_number = 4;
    assert (select visit_number from public.fetch_shop_reviews(shop_id, 8) where id = review_id) = 2,
        '페이지 밖의 리뷰도 전체 남은 방문을 기준으로 센다';
    page := public.fetch_review_feed_page('2026-06-06', 'ffffffff-ffff-ffff-ffff-ffffffffffff');
    assert (select (r->'review'->>'visit_number')::int from jsonb_array_elements(page->'reviews') r
        where r->'review'->>'id' = review_id::text) = 2, '커서 다음 페이지도 전체 남은 방문을 기준으로 센다';
    assert not has_function_privilege('anon', 'community_private.count_review_visits(uuid,uuid,integer)', 'execute'),
        '비로그인 사용자는 내부 방문 집계 함수를 직접 호출할 수 없다';
    assert not has_function_privilege('authenticated', 'community_private.count_review_visits(uuid,uuid,integer)', 'execute'),
        '로그인 사용자는 내부 방문 집계 함수를 직접 호출할 수 없다';
end;
$$;
rollback;
