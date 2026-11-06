-- Run only in a disposable database with the deployed v1/v2 review RPCs,
-- their dependency fixtures, and the increase_review_body_limit_to_100 migration.
-- The caller must set ramap.test_disposable = 'on'. All fixture rows roll back.
begin;

do $test$
declare
    owner_id uuid := gen_random_uuid();
    shop_id uuid := gen_random_uuid();
    review_id uuid;
    candidate_body text;
    rpc text;
    target_id uuid;
    should_accept boolean;
    accepted boolean;
    violated_constraint text;
    checked integer := 0;
begin
    assert current_setting('ramap.test_disposable', true) is not distinct from 'on', '일회용 테스트 DB에서만 실행합니다';
    insert into public.ramen_shops(id, name) values (shop_id, '리뷰 길이 테스트');
    insert into public.public_profiles(user_id, nickname) values (owner_id, '테스트 작성자');
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    review_id := public.submit_shop_review(shop_id, '12345', '{}', true);

    foreach candidate_body in array array[
        '1234', '12345', repeat('가', 31), repeat('가', 100), repeat('가', 101),
        repeat('🍜', 100), repeat('🍜', 101), repeat('가🍜', 50),
        ' ' || repeat('가', 100), repeat('가', 100) || ' ', null::text
    ] loop
        should_accept := coalesce(candidate_body = btrim(candidate_body) and char_length(candidate_body) between 5 and 100, false);
        foreach rpc in array array['submit_shop_review', 'submit_shop_review_v2', 'update_shop_review', 'update_shop_review_v2'] loop
            target_id := case when rpc like 'submit_%' then shop_id else review_id end;
            accepted := false;
            begin
                execute format('select public.%I($1, $2, $3, $4)', rpc)
                    using target_id, candidate_body, array[]::text[], true;
                accepted := true;
            exception when raise_exception then
                assert sqlerrm = 'Invalid review', format('예상하지 않은 오류: %s', sqlerrm);
            end;
            assert accepted = should_accept, format('%s의 %s자 본문 검증 결과가 다릅니다', rpc, char_length(candidate_body));
            checked := checked + 1;
        end loop;
    end loop;

    foreach candidate_body in array array['1234', '12345', repeat('가', 31), repeat('가', 100), repeat('가', 101), repeat('🍜', 100), repeat('🍜', 101)] loop
        should_accept := char_length(candidate_body) between 5 and 100;
        accepted := false;
        begin
            update public.shop_reviews set body = candidate_body where id = review_id;
            accepted := true;
        exception when check_violation then
            get stacked diagnostics violated_constraint = constraint_name;
            assert violated_constraint = 'shop_reviews_body_character_length', '본문 길이 제약으로 거부해야 합니다';
        end;
        assert accepted = should_accept, format('테이블의 %s자 본문 검증 결과가 다릅니다', char_length(candidate_body));
        checked := checked + 1;
    end loop;
    raise notice '리뷰 본문 길이 경계 검증 %개 통과', checked;
end;
$test$;

rollback;
