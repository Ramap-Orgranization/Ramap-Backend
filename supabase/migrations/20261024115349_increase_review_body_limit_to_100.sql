-- Keep the deployed RPC guards, replay protection and function permissions.
CREATE OR REPLACE FUNCTION public.submit_shop_review(p_shop_id uuid, p_body text, p_image_paths text[] DEFAULT '{}'::text[], p_is_public boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
declare review_id uuid;
declare image_path text;
declare image_object_id uuid;
declare canonical_payload text;
begin
    current_user_id := community_private.require_live_user();
    if p_shop_id is null
       or p_body is null or p_body <> btrim(p_body) or char_length(p_body) not between 5 and 100
       or p_is_public is null
       or p_image_paths is null or cardinality(p_image_paths) > 3
       or coalesce(array_ndims(p_image_paths), 1) <> 1
       or cardinality(p_image_paths) <> (select count(distinct path) from unnest(p_image_paths) path)
       or not public.shop_review_image_paths_belong_to_user(p_image_paths, current_user_id)
       or not exists (select 1 from public.ramen_shops where id = p_shop_id)
    then
        raise exception 'Invalid review';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.review-submit.' || current_user_id::text, 0));
    for image_path in
        select path from unnest(p_image_paths) path order by path
    loop
        perform pg_advisory_xact_lock(hashtextextended(image_path, 0));
        select id into image_object_id from storage.objects
        where bucket_id = 'shop-review-images' and name = image_path for update;
        if image_object_id is null then raise exception 'Review image not found'; end if;
    end loop;
    canonical_payload := pg_catalog.jsonb_build_object('shop_id', p_shop_id, 'body', p_body, 'image_paths', p_image_paths, 'is_public', p_is_public)::text;
    review_id := review_submission_private.reserve_submission(canonical_payload);
    if review_id is not null then return review_id; end if;
    if exists (
        select 1 from public.shop_reviews where image_paths && p_image_paths
    ) then
        raise exception 'Review image already submitted';
    end if;
    perform account_profile_private.fetch_or_create_my_profile(current_user_id);
    insert into public.shop_reviews(shop_id, user_id, body, image_paths, moderation_status, is_public)
    values (p_shop_id, current_user_id, p_body, p_image_paths, 'published', p_is_public) returning id into review_id;
    perform review_submission_private.remember_submission(canonical_payload, review_id);
    return review_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_shop_review(p_review_id uuid, p_body text, p_image_paths text[], p_is_public boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
declare image_path text;
declare image_object_id uuid;
begin
    current_user_id := community_private.require_current_member();
    if p_review_id is null
       or p_body is null or p_body <> btrim(p_body) or char_length(p_body) not between 5 and 100
       or p_is_public is null
       or p_image_paths is null or cardinality(p_image_paths) > 3
       or coalesce(array_ndims(p_image_paths), 1) <> 1
       or cardinality(p_image_paths) <> (select count(distinct path) from unnest(p_image_paths) path)
       or not public.shop_review_image_paths_belong_to_user(p_image_paths, current_user_id)
    then
        raise exception 'Invalid review';
    end if;
    perform 1 from public.shop_reviews r
    where r.id = p_review_id and r.user_id = current_user_id for update;
    if not found then raise exception 'Invalid review'; end if;
    for image_path in select path from unnest(p_image_paths) path order by path loop
        perform pg_advisory_xact_lock(hashtextextended(image_path, 0));
        select id into image_object_id from storage.objects
        where bucket_id = 'shop-review-images' and name = image_path for update;
        if image_object_id is null then raise exception 'Review image not found'; end if;
    end loop;
    if exists (
        select 1 from public.shop_reviews r
        where r.id <> p_review_id and r.image_paths && p_image_paths
    ) then
        raise exception 'Review image already submitted';
    end if;
    update public.shop_reviews
    set body = p_body, image_paths = p_image_paths, is_public = p_is_public
    where id = p_review_id;
    return p_review_id;
end;
$function$;

ALTER TABLE public.shop_reviews
    DROP CONSTRAINT shop_reviews_body_character_length,
    ADD CONSTRAINT shop_reviews_body_character_length
        CHECK (body = btrim(body) AND char_length(body) BETWEEN 5 AND 100);
