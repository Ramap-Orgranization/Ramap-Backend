-- Run only in a disposable database with the deployed v1 RPC definitions, the v2
-- migration and a minimal shops/profiles/reviews/storage/auth fixture.
-- review_mutation_v1_baseline captures pg_get_functiondef/proacl before migration.
begin;

do $$
declare
    owner_id uuid := gen_random_uuid();
    other_id uuid := gen_random_uuid();
    shop_id uuid := gen_random_uuid();
    first_id uuid;
    second_id uuid;
    receipt jsonb;
    projection jsonb;
    image_path text := owner_id::text || '/receipt-fixture.jpg';
    missing_image_path text := owner_id::text || '/missing-fixture.jpg';
begin
    assert (select count(*) = 3 from review_mutation_v1_baseline baseline
        join pg_catalog.pg_proc current_function on current_function.oid = baseline.oid),
        'v1 functions are not dropped and recreated';
    assert not exists (
        select 1 from review_mutation_v1_baseline baseline
        join pg_catalog.pg_proc current_function on current_function.oid = baseline.oid
        where baseline.definition is distinct from pg_get_functiondef(current_function.oid)
           or baseline.proacl is distinct from current_function.proacl
    ), 'v1 definitions and execute permissions remain unchanged';
    assert pg_get_function_result('public.submit_shop_review(uuid,text,text[],boolean)'::regprocedure) = 'uuid'
        and pg_get_function_result('public.update_shop_review(uuid,text,text[],boolean)'::regprocedure) = 'uuid'
        and pg_get_function_result('public.delete_shop_review(uuid)'::regprocedure) = 'uuid',
        'deployed write RPCs keep UUID responses';

    assert not has_function_privilege('anon', 'public.submit_shop_review_v2(uuid,text,text[],boolean)', 'execute')
        and not has_function_privilege('anon', 'public.update_shop_review_v2(uuid,text,text[],boolean)', 'execute')
        and not has_function_privilege('anon', 'public.delete_shop_review_v2(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.fetch_my_review_projection_v2(uuid)', 'execute'),
        'new RPCs reject anonymous callers';
    assert has_function_privilege('authenticated', 'public.submit_shop_review_v2(uuid,text,text[],boolean)', 'execute')
        and has_function_privilege('authenticated', 'public.update_shop_review_v2(uuid,text,text[],boolean)', 'execute')
        and has_function_privilege('authenticated', 'public.delete_shop_review_v2(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.fetch_my_review_projection_v2(uuid)', 'execute'),
        'authenticated callers can use v2';
    assert not has_function_privilege('authenticated', 'community_private.review_mutation_snapshot(uuid)', 'execute')
        and not has_function_privilege('anon', 'community_private.review_mutation_snapshot(uuid)', 'execute')
        and not has_function_privilege('authenticated', 'community_private.review_owner_counts(uuid)', 'execute'),
        'internal snapshot and count helpers are not public APIs';

    insert into public.ramen_shops(id, name) values (shop_id, 'receipt fixture');
    insert into public.public_profiles(user_id, nickname) values (owner_id, 'owner fixture'), (other_id, 'other fixture');
    insert into storage.objects(bucket_id, name) values ('shop-review-images', image_path);
    perform set_config('request.jwt.claim.sub', owner_id::text, true);

    first_id := public.submit_shop_review(shop_id, 'legacy review', array[image_path], true);
    update public.shop_reviews set created_at = '2026-01-01 00:00:00+00' where id = first_id;
    insert into public.review_likes(review_id, user_id) values (first_id, other_id);

    receipt := public.submit_shop_review_v2(shop_id, 'created review', '{}', true);
    second_id := (receipt ->> 'review_id')::uuid;
    assert receipt -> 'before' = 'null'::jsonb and receipt -> 'after' ->> 'id' = second_id::text,
        'create returns the committed server ID and a complete after snapshot';
    assert receipt ->> 'user_id' = owner_id::text and receipt ->> 'shop_id' = shop_id::text
        and receipt -> 'after' ->> 'user_id' = owner_id::text
        and receipt -> 'after' ->> 'nickname' = 'owner fixture'
        and receipt -> 'after' ->> 'shop_name' = 'receipt fixture',
        'snapshot provides real author and shop metadata';
    assert (receipt -> 'after' ->> 'author_review_count')::integer = 2
        and (receipt -> 'after' ->> 'visit_number')::integer = 2
        and (receipt -> 'owner_counts' ->> 'total_count')::integer = 2
        and (receipt -> 'owner_counts' ->> 'public_count')::integer = 2
        and (receipt -> 'owner_counts' ->> 'published_count')::integer = 2,
        'create computes author/visit baselines and owner counts after insertion';

    receipt := public.update_shop_review_v2(first_id, 'updated review', array[image_path], false);
    assert (receipt -> 'before' ->> 'is_public')::boolean
        and not (receipt -> 'after' ->> 'is_public')::boolean
        and receipt -> 'before' -> 'image_paths' = jsonb_build_array(image_path)
        and receipt -> 'after' ->> 'body' = 'updated review'
        and (receipt -> 'after' ->> 'like_count')::integer = 1
        and not (receipt -> 'after' ->> 'is_liked')::boolean,
        'update captures previous visibility/paths and complete feed fields';
    assert (receipt -> 'owner_counts' ->> 'public_count')::integer = 1
        and (receipt -> 'owner_counts' ->> 'private_count')::integer = 1
        and (receipt -> 'owner_counts' ->> 'published_count')::integer = 1,
        'visibility transition returns authoritative counts';

    update public.shop_reviews set moderation_status = 'pending', moderation_note = 'fixture moderation' where id = second_id;
    receipt := public.update_shop_review_v2(second_id, 'pending review', '{}', true);
    assert receipt -> 'before' ->> 'moderation_status' = 'pending'
        and receipt -> 'after' ->> 'moderation_status' = 'pending'
        and receipt -> 'after' ->> 'moderation_note' = 'fixture moderation'
        and (receipt -> 'owner_counts' ->> 'public_count')::integer = 1
        and (receipt -> 'owner_counts' ->> 'published_count')::integer = 0,
        'update retains moderation and distinguishes public from public/published counts';

    perform set_config('request.jwt.claim.sub', other_id::text, true);
    assert public.fetch_my_review_projection_v2(first_id) is null, 'projection never reveals another owners private review';
    begin
        perform public.update_shop_review_v2(first_id, 'forbidden review', '{}', true);
        raise check_violation using message = 'another owner update was accepted';
    exception when raise_exception then
        assert sqlerrm = 'Invalid review', 'update still enforces ownership';
    end;
    begin
        perform public.delete_shop_review_v2(first_id);
        raise check_violation using message = 'another owner delete was accepted';
    exception when raise_exception then
        assert sqlerrm = 'Invalid review', 'delete still enforces ownership';
    end;
    perform set_config('request.jwt.claim.sub', owner_id::text, true);

    begin
        perform public.submit_shop_review_v2(shop_id, 'invalid image', array[missing_image_path], true);
        raise check_violation using message = 'unuploaded image was accepted';
    exception when raise_exception then
        assert sqlerrm = 'Review image not found', 'v2 preserves v1 image validation';
    end;
    assert (select count(*) = 2 from public.shop_reviews where user_id = owner_id),
        'rejected write has no partial insert';

    projection := public.fetch_my_review_projection_v2(first_id);
    assert projection ->> 'id' = first_id::text and (projection ->> 'like_count')::integer = 1,
        'same-ID recovery supplies the complete projection';
    receipt := public.delete_shop_review_v2(first_id);
    assert receipt -> 'before' ->> 'id' = first_id::text
        and receipt -> 'before' -> 'image_paths' = jsonb_build_array(image_path)
        and not (receipt -> 'before' ->> 'is_public')::boolean
        and receipt -> 'after' = 'null'::jsonb
        and (receipt -> 'owner_counts' ->> 'total_count')::integer = 1
        and (receipt -> 'owner_counts' ->> 'private_count')::integer = 0
        and (receipt -> 'owner_counts' ->> 'public_count')::integer = 1,
        'delete retains prior metadata and counts even when removed row is outside public filter';
    assert public.fetch_my_review_projection_v2(first_id) is null, 'deleted row stays absent';
    assert public.delete_shop_review(second_id) = second_id, 'legacy UUID deletion continues to work';

    perform set_config('request.jwt.claim.sub', '', true);
    begin
        perform public.fetch_my_review_projection_v2(second_id);
        raise check_violation using message = 'unauthenticated projection was accepted';
    exception when insufficient_privilege then
        null;
    end;
end;
$$;

rollback;
