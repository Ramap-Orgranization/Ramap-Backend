-- Run only in the disposable database created by photo_only_reviews_test.py.
begin;

do $$
declare
    owner_id uuid := '00000000-0000-0000-0000-000000000001';
    shop_id uuid := '00000000-0000-0000-0000-000000000002';
    existing_path text := owner_id::text || '/existing.jpg';
    new_path text := owner_id::text || '/new.jpg';
    existing_review_id uuid;
    target_id uuid;
    photo_paths text[];
    candidate_body text;
    rpc text;
begin
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    select id into strict existing_review_id from public.shop_reviews
        where user_id = owner_id and body = '' and image_paths = array[existing_path];

    foreach rpc in array array['submit_shop_review', 'submit_shop_review_v2', 'update_shop_review', 'update_shop_review_v2'] loop
        target_id := case when rpc like 'submit_%' then shop_id else existing_review_id end;
        photo_paths := case when rpc like 'submit_%' then array[new_path] else array[existing_path] end;
        foreach candidate_body in array array['', '1234', E'\t\t\t\t\t', U&'\00A0\00A0\00A0\00A0\00A0'] loop
            begin
                execute format('select public.%I($1, $2, $3, $4)', rpc)
                    using target_id, candidate_body, photo_paths, true;
                raise exception '%: 5자 미만인 본문을 허용했습니다', rpc;
            exception when raise_exception then
                assert sqlerrm = 'Invalid review', format('%s: 예상하지 않은 오류 %s', rpc, sqlerrm);
            end;
        end loop;

        execute format('select public.%I($1, $2, $3, $4)', rpc) using target_id, '라멘맛있다', photo_paths, true;
    end loop;

    assert exists (
        select 1 from public.shop_reviews
        where id = existing_review_id and body = '라멘맛있다' and image_paths = array[existing_path]
    ), '기존 사진은 그대로 두고 5자 본문을 저장해야 합니다';
end;
$$;

rollback;
