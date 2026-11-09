-- Run only against the disposable fixture using review_visit_numbers_test.py.
begin;

insert into auth.users(id) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
insert into public.public_profiles(user_id, nickname, is_public) values
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '작성자', true),
    ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '독자', true);
insert into public.ramen_shops(id, name) values
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '테스트 매장');
insert into public.shop_reviews(id, shop_id, user_id, body, is_public, moderation_status)
select r.id, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
       r.body, r.is_public, r.moderation_status
from (values
    ('dddddddd-dddd-4ddd-8ddd-dddddddddddd'::uuid, '게시된 리뷰', true, 'published'),
    ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'::uuid, '비공개 리뷰', false, 'published'),
    ('ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid, '검수 중인 리뷰', true, 'pending')
) as r(id, body, is_public, moderation_status);

set local role authenticated;

do $$
declare
    author constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    reader constant uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    published_review constant uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    ineligible_review uuid;
begin
    perform set_config('request.jwt.claim.sub', reader::text, true);
    assert (select (like_count, is_liked) = (1, true) from public.set_review_like(published_review, true)),
        '다른 사람의 공개 리뷰에는 계속 좋아요를 누를 수 있음';

    perform set_config('request.jwt.claim.sub', author::text, true);
    assert (select (like_count, is_liked) = (2, true) from public.set_review_like(published_review, true)),
        '작성자 본인도 게시된 공개 리뷰에 좋아요를 누를 수 있음';
    assert (select (like_count, is_liked) = (2, true) from public.set_review_like(published_review, true)),
        '같은 요청을 반복해도 한 번만 집계됨';
    assert (select (like_count, is_liked) = (1, false) from public.set_review_like(published_review, false)),
        '취소 시 작성자 본인의 좋아요만 제거됨';

    foreach ineligible_review in array array[
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'::uuid,
        'ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid
    ] loop
        begin
            perform public.set_review_like(ineligible_review, true);
            raise exception '비공개 또는 검수 중인 리뷰의 좋아요 요청이 허용됨';
        exception when raise_exception then
            if sqlerrm <> 'Invalid review like' then raise; end if;
        end;
    end loop;
end;
$$;

rollback;
