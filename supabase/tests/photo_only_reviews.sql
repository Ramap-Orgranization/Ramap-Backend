-- Run only in the disposable database created by photo_only_reviews_test.py.
begin;

create function pg_temp.reject_review(
    p_rpc text, p_target uuid, p_body text, p_paths text[], p_error text default 'Invalid review'
) returns void language plpgsql as $$
begin
    begin
        execute format('select public.%I($1, $2, $3, $4)', p_rpc)
            using p_target, p_body, p_paths, true;
        raise exception '거절해야 하는 리뷰를 허용했습니다';
    exception when raise_exception then
        assert sqlerrm = p_error, format('%s의 예상하지 않은 오류: %s', p_rpc, sqlerrm);
    end;
end;
$$;

do $$
declare
    owner_id uuid := gen_random_uuid();
    other_id uuid := gen_random_uuid();
    shop_id uuid := gen_random_uuid();
    review_id uuid;
    photo_review_id uuid;
    candidate_body text;
    paths text[];
    path text;
    rpc text;
    photo_count integer;
    should_accept boolean;
    accepted boolean;
    violated_constraint text;
    upload jsonb;
    receipt jsonb;
    checked integer := 0;
begin
    insert into auth.users(id) values (owner_id), (other_id);
    insert into public.public_profiles(user_id, nickname) values (owner_id, '사진 리뷰 작성자');
    insert into public.ramen_shops(id, name) values (shop_id, '사진 리뷰 테스트');
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    update review_submission_private.settings set actor_minute_limit = 10000, actor_daily_limit = 100000;
    review_id := public.submit_shop_review(shop_id, '12345', '{}', true);

    foreach candidate_body in array array[
        '', ' ', E'\t\n', '1234', '12345', repeat('가', 100), repeat('가', 101),
        repeat('🍜', 100), repeat('🍜', 101), ' 12345', '12345 ', null::text
    ] loop
        for photo_count in 0..4 loop
            should_accept := photo_count <= 3 and coalesce(
                candidate_body = btrim(candidate_body) and (
                    char_length(candidate_body) between 5 and 100
                    or (candidate_body = '' and photo_count > 0)
                ), false
            );
            foreach rpc in array array['submit_shop_review', 'submit_shop_review_v2', 'update_shop_review', 'update_shop_review_v2'] loop
                paths := '{}';
                for photo_index in 1..photo_count loop
                    path := owner_id::text || '/' || gen_random_uuid()::text || '.jpg';
                    paths := array_append(paths, path);
                    insert into storage.objects(bucket_id, name, owner)
                        values ('shop-review-images', path, owner_id);
                end loop;
                shop_id := gen_random_uuid();
                insert into public.ramen_shops(id, name) values (shop_id, '경계 테스트');
                accepted := false;
                begin
                    execute format('select public.%I($1, $2, $3, $4)', rpc)
                        using case when rpc like 'submit_%' then shop_id else review_id end,
                            candidate_body, paths, true;
                    accepted := true;
                exception when raise_exception then
                    assert sqlerrm = 'Invalid review', format('%s의 예상하지 않은 오류: %s', rpc, sqlerrm);
                end;
                assert accepted = should_accept,
                    format('%s의 본문 %L / 사진 %s개 검증 결과가 다릅니다', rpc, candidate_body, photo_count);
                checked := checked + 1;
            end loop;

            -- Direct writes must obey the same content requirement.
            accepted := false;
            begin
                update public.shop_reviews set body = candidate_body, image_paths = paths where id = review_id;
                accepted := true;
            exception when check_violation then
                get stacked diagnostics violated_constraint = constraint_name;
                assert violated_constraint = 'shop_reviews_body_character_length', '본문과 사진 제약으로 거부해야 합니다';
            end;
            -- The production table's separate image-count constraint is outside this fixture.
            if photo_count <= 3 then
                assert accepted = should_accept, '테이블이 빈 리뷰나 잘못된 본문을 허용했습니다';
            end if;
        end loop;
    end loop;

    path := owner_id::text || '/' || gen_random_uuid()::text || '.jpg';
    insert into storage.objects(bucket_id, name, owner) values ('shop-review-images', path, owner_id);
    paths := array[path];
    receipt := public.submit_shop_review_v2(shop_id, '', paths, false);
    photo_review_id := (receipt->>'review_id')::uuid;
    assert receipt->'after'->>'body' = '' and receipt->'after'->'image_paths' = to_jsonb(paths),
        '작성 응답이 빈 본문과 사진을 보존해야 합니다';
    assert (public.submit_shop_review_v2(shop_id, '', paths, false)->>'review_id')::uuid = photo_review_id,
        '사진만 있는 리뷰를 재전송해도 한 번만 저장해야 합니다';
    receipt := public.update_shop_review_v2(photo_review_id, '', paths, true);
    assert (receipt->'after'->>'is_public')::boolean and receipt->'after'->>'body' = '',
        '기존 사진을 유지한 빈 본문 수정과 공개 전환을 허용해야 합니다';
    perform pg_temp.reject_review('update_shop_review_v2', photo_review_id, '', '{}');
    perform pg_temp.reject_review('submit_shop_review', shop_id, '', paths, 'Review image already submitted');

    foreach rpc in array array['submit_shop_review', 'submit_shop_review_v2', 'update_shop_review', 'update_shop_review_v2'] loop
        perform pg_temp.reject_review(rpc, case when rpc like 'submit_%' then shop_id else photo_review_id end, '', null);
        perform pg_temp.reject_review(rpc, case when rpc like 'submit_%' then shop_id else photo_review_id end, '', array[path, path]);
        perform pg_temp.reject_review(rpc, case when rpc like 'submit_%' then shop_id else photo_review_id end, '', array[null::text]);
        perform pg_temp.reject_review(rpc, case when rpc like 'submit_%' then shop_id else photo_review_id end, '', array[other_id::text || '/other.jpg']);
    end loop;

    perform set_config('request.jwt.claim.role', 'service_role', true);
    perform public.configure_media_storage(true, true, false);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    path := owner_id::text || '/' || gen_random_uuid()::text || '.jpg';
    upload := public.prepare_media_upload('shop-review-images', path, 'image/jpeg', 100);
    foreach rpc in array array['submit_shop_review', 'submit_shop_review_v2', 'update_shop_review', 'update_shop_review_v2'] loop
        perform pg_temp.reject_review(rpc, case when rpc like 'submit_%' then shop_id else photo_review_id end,
            '', array[path], 'Review image not found');
    end loop;
    perform set_config('request.jwt.claim.role', 'service_role', true);
    perform public.register_media_upload_target((upload->>'id')::uuid, 'test-private', 'test-private');
    perform public.complete_media_upload((upload->>'id')::uuid, 'test-private', 'shop-review-images/' || path,
        '1', 100, 'image/jpeg', repeat('a', 64));
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    receipt := public.update_shop_review_v2(photo_review_id, '', array[path], true);
    assert receipt->'after'->'image_paths' = to_jsonb(array[path]), '업로드가 확정된 새 사진으로 교체할 수 있어야 합니다';

    perform set_config('request.jwt.claim.sub', other_id::text, true);
    perform pg_temp.reject_review('update_shop_review_v2', photo_review_id, '', '{}');
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    foreach rpc in array array['submit_shop_review', 'submit_shop_review_v2', 'update_shop_review', 'update_shop_review_v2'] loop
        assert not has_function_privilege('anon', format('public.%I(uuid,text,text[],boolean)', rpc), 'execute'),
            '익명 작성과 수정 권한을 추가하지 않아야 합니다';
        assert has_function_privilege('authenticated', format('public.%I(uuid,text,text[],boolean)', rpc), 'execute'),
            '로그인한 사용자의 작성과 수정 권한을 유지해야 합니다';
    end loop;
    raise notice '본문·사진 조합 %개와 저장 경계 검증 통과', checked;
end;
$$;

rollback;
