-- Run only against the disposable fixture using review_visit_numbers_test.py.
begin;

do $$
declare
    author constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    private_author constant uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    viewer constant uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    shop constant uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    public_review constant uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    private_review constant uuid := 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    source_photo constant text := author::text || '/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg';
    copied_photo constant text := 'withdrawn/' || public_review::text || '/1.jpg';
    projection record;
begin
    insert into auth.users values (author), (private_author), (viewer);
    insert into public.public_profiles(user_id, nickname, is_public, avatar_path)
    values (author, '기존닉네임', true, 'old-avatar.jpg'), (private_author, '비공개닉네임', false, null),
           (viewer, '독자닉네임', true, null);
    insert into public.ramen_shops(id, name) values (shop, '테스트 매장');
    insert into public.shop_reviews(id, shop_id, user_id, body, image_paths)
    values (public_review, shop, author, '', array[source_photo]),
           (private_review, shop, private_author, '프로필이 비공개인 리뷰', '{}');
    insert into public.shop_reviews(shop_id, user_id, body, is_public, moderation_status)
    values (shop, author, '비공개 리뷰', false, 'published'),
           (shop, author, '검수 중인 리뷰', true, 'pending');
    insert into public.review_likes values (public_review, viewer);
    insert into public.community_reports(
        reporter_id, target_user_id, review_id, target_type, target_id,
        review_image_paths_snapshot, profile_nickname_snapshot
    )
    values (viewer, author, public_review, 'review', public_review, array[source_photo], '기존닉네임');
    insert into public.user_shop_bookmarks values (viewer, shop);
    insert into public.profile_follows values (viewer, author, 'following');
    insert into public.account_deletion_requests values (author);
    insert into storage.objects(bucket_id, name, owner, owner_id)
    values ('shop-review-images', source_photo, author, author::text), ('profile-avatars', 'old-avatar.jpg', author, author::text);
    insert into media_private.objects values (public_review, author, source_photo, 'ready');

    assert not has_function_privilege('authenticated', 'public.list_account_review_photo_copies(uuid)', 'execute'),
        '일반 사용자가 복사 계획을 조회할 수 없음';
    perform set_config('request.jwt.claim.role', 'service_role', true);
    assert (select destination_path from public.list_account_review_photo_copies(author)) = copied_photo;
    begin
        perform public.prepare_account_media_cleanup(author);
        raise exception '복사 완료 전 정리가 시작됨';
    exception when object_not_in_prerequisite_state then null;
    end;
    assert (select state from media_private.objects where id = public_review) = 'ready';
    begin
        perform public.list_account_owned_storage(author);
        raise exception '복사 전 Supabase 원본이 삭제 대상으로 조회됨';
    exception when object_not_in_prerequisite_state then null;
    end;
    begin
        delete from auth.users where id = author;
        raise exception '복사 전 Auth 삭제가 허용됨';
    exception when object_not_in_prerequisite_state then null;
    end;

    insert into storage.objects(bucket_id, name) values ('shop-review-images', copied_photo);
    assert not exists (select 1 from public.list_review_image_orphans(now() + interval '1 day') where name = copied_photo);
    assert not exists (select 1 from public.list_account_review_photo_copies(author)), '재시도 시 완료된 복사를 건너뜀';
    perform public.prepare_account_media_cleanup(author);
    perform public.prepare_account_media_cleanup(author);
    assert (select image_paths from public.shop_reviews where id = public_review) = array[copied_photo];
    assert (select state from media_private.objects where id = public_review) = 'deleting';
    assert (select count(*) from public.list_account_owned_storage(author)) = 2, '계정 원본과 아바타만 정리';
    assert not exists (select 1 from public.list_account_owned_storage(author) where name = copied_photo);
    assert (public.fetch_shop_reviews_page(shop)->>'total_count')::int = 0, '계정 삭제 전에는 계속 숨김';

    delete from storage.objects where owner = author;
    delete from auth.users where id in (author, private_author);
    assert not exists (select 1 from public.public_profiles where user_id in (author, private_author));
    assert (select count(*) from public.shop_reviews where user_id is null) = 4, '기존 리뷰 행을 모두 보존';
    assert (select is_public from public.shop_reviews where id = private_review) = false, '비공개 프로필의 리뷰 공개 방지';
    assert (select target_user_id is null and profile_nickname_snapshot = '탈퇴한 사용자'
            and review_image_paths_snapshot is null
            from public.community_reports where review_id = public_review), '기존 리뷰 신고에서 계정 정보만 분리';

    select * into strict projection from public.fetch_shop_reviews(shop);
    assert projection.id = public_review and projection.body = '' and projection.image_paths = array[copied_photo];
    assert projection.nickname = '탈퇴한 사용자' and projection.avatar_path is null
        and projection.user_id = '' and projection.is_withdrawn and projection.visit_number = 1;
    assert (public.fetch_shop_reviews_page(shop)->>'total_count')::int = 1;
    assert public.fetch_review_feed_page()#>>'{reviews,0,review,user_id}' = '';
    assert (public.fetch_review_feed_page()#>>'{reviews,0,review,is_withdrawn}')::boolean;
    assert public.fetch_shop_reviews_page(shop)#>>'{reviews,0,user_id}' = '';
    assert (public.fetch_popular_review_feed_page()#>>'{reviews,0,review,like_count}')::int = 1;
    assert community_private.can_read_review_image(copied_photo);
    assert not community_private.can_read_review_image(source_photo);
    perform set_config('request.jwt.claim.sub', viewer::text, true);
    assert jsonb_array_length(feed_private.fetch_filtered_review_feed_page('saved_shops')->'reviews') = 1;
    assert jsonb_array_length(feed_private.fetch_filtered_review_feed_page('following')->'reviews') = 0;
    assert (select like_count from public.set_review_like(public_review, false)) = 0;
    update public.community_reports set status = 'resolved' where review_id = public_review;
    perform public.report_community_content('review', public_review, 'privacy');
    assert (select target_user_id is null and review_image_paths_snapshot = array[copied_photo]
            from public.community_reports where review_id = public_review and status = 'pending');
    update public.ramen_shops set is_visible = false where id = shop;
    assert not exists (select 1 from public.fetch_shop_reviews(shop));
    assert not community_private.can_read_review_image(copied_photo);
end;
$$;

rollback;
