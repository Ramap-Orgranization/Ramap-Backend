-- Run with psql -v ON_ERROR_STOP=1 -f supabase/tests/shop_review_likes.sql against an empty, disposable database.
\ir fixtures/review_visit_numbers.sql
\ir ../migrations/20261026080230_review_feed_filters.sql
\ir ../migrations/20261026105129_review_feed_filter_target_presence.sql
\ir ../migrations/20261031152722_count_remaining_review_visits.sql
\ir fixtures/withdrawn_reviews.sql
\ir ../migrations/20261106032843_preserve_withdrawn_account_reviews.sql
\ir ../migrations/20261109153431_allow_self_review_likes.sql
\ir ../migrations/20261111144719_restore_review_like_state.sql

begin;

do $$
declare
    author constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    reader constant uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    shop constant uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    public_review constant uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    private_review constant uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    pending_review constant uuid := 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    rejected_review uuid;
    projection jsonb;
begin
    insert into auth.users values (author), (reader);
    insert into public.public_profiles(user_id, nickname, is_public) values (author, '작성자', true), (reader, '독자', true);
    insert into public.ramen_shops(id, name) values (shop, '테스트 매장');
    insert into public.shop_reviews(id, shop_id, user_id, body, is_public, moderation_status)
    values (public_review, shop, author, '공개된 리뷰입니다', true, 'published'),
           (private_review, shop, author, '비공개 리뷰입니다', false, 'published'),
           (pending_review, shop, author, '검수 중인 리뷰입니다', true, 'pending');

    perform set_config('request.jwt.claim.sub', author::text, true);
    assert (select is_liked and like_count = 1 from public.set_review_like(public_review, true)), '본인 공개 리뷰 좋아요';
    assert (select is_liked and like_count = 1 from public.set_review_like(public_review, true)), '중복 요청에서 좋아요 개수 유지';
    select item into strict projection from jsonb_array_elements(public.fetch_shop_reviews_page(shop)->'reviews') item
    where item->>'id' = public_review::text;
    assert (projection->>'is_liked')::boolean and (projection->>'like_count')::integer = 1, '재조회에서 본인의 좋아요 표시';

    foreach rejected_review in array array[private_review, pending_review] loop
        begin
            perform public.set_review_like(rejected_review, true);
            raise exception '비공개·검수 중 리뷰 좋아요가 허용됨';
        exception when raise_exception then
            assert sqlerrm = 'Invalid review like';
        end;
    end loop;

    update public.public_profiles set is_public = false where user_id = author;
    begin
        perform public.set_review_like(public_review, true);
        raise exception '비공개 프로필의 본인 리뷰 좋아요가 허용됨';
    exception when raise_exception then
        assert sqlerrm = 'Invalid review like';
    end;
    update public.public_profiles set is_public = true where user_id = author;

    perform set_config('request.jwt.claim.sub', reader::text, true);
    select item into strict projection from jsonb_array_elements(public.fetch_shop_reviews_page(shop)->'reviews') item;
    assert not (projection->>'is_liked')::boolean and (projection->>'like_count')::integer = 1, '계정별 좋아요 상태 분리';
    assert (select is_liked and like_count = 2 from public.set_review_like(public_review, true)), '다른 사용자 좋아요';

    perform set_config('request.jwt.claim.sub', author::text, true);
    assert (select not is_liked and like_count = 1 from public.set_review_like(public_review, false)), '본인 좋아요만 취소';
    select item into strict projection from jsonb_array_elements(public.fetch_shop_reviews_page(shop)->'reviews') item
    where item->>'id' = public_review::text;
    assert not (projection->>'is_liked')::boolean and (projection->>'like_count')::integer = 1, '재조회에서 본인 취소 상태 반영';

    perform set_config('request.jwt.claim.sub', '', true);
    select item into strict projection from jsonb_array_elements(public.fetch_shop_reviews_page(shop)->'reviews') item;
    assert not (projection->>'is_liked')::boolean and (projection->>'like_count')::integer = 1, '비회원은 개수만 조회';

    perform set_config('request.jwt.claim.sub', reader::text, true);
    insert into public.user_blocks values (reader, author);
    select item into strict projection from jsonb_array_elements(public.fetch_shop_reviews_page(shop)->'reviews') item;
    assert (projection->>'is_blocked')::boolean and not (projection->>'is_liked')::boolean
        and (projection->>'like_count')::integer = 0, '차단 리뷰는 좋아요 상태를 숨김';
end;
$$;

rollback;
