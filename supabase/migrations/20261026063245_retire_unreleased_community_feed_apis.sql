-- Replace feed compatibility wrappers with their existing guarded implementations.
-- CREATE OR REPLACE keeps the feed API signatures and existing EXECUTE grants.
CREATE OR REPLACE FUNCTION public.fetch_review_feed_page(p_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_review_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    viewer uuid := auth.uid();
    result jsonb;
    rows jsonb;
begin
    if (p_created_at is null) <> (p_review_id is null)
       or (p_created_at is not null and not pg_catalog.isfinite(p_created_at)) then
        raise exception 'Invalid community cursor' using errcode = '22023';
    end if;

    with eligible as materialized (
        select r.*, p.nickname, p.avatar_path,
               exists (
                   select 1 from public.user_blocks b
                   where b.blocker_id = viewer and b.blocked_id = r.user_id
               ) as is_blocked
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        where r.is_public and r.moderation_status = 'published'
          and p.is_public and p.suspended_at is null
          and not exists (
              select 1 from public.account_deletion_requests d where d.user_id = r.user_id
          )
          and (p_created_at is null or (r.created_at, r.id) < (p_created_at, p_review_id))
        order by r.created_at desc, r.id desc
        limit 11
    ), page as materialized (
        select * from eligible order by created_at desc, id desc limit 10
    ), payload as (
        select r.id, r.shop_id,
               case when r.is_blocked then ''::text else r.body end as body,
               r.created_at,
               case when r.is_blocked then array[]::text[] else r.image_paths end as image_paths,
               r.user_id,
               case when r.is_blocked then ''::text else r.nickname end as nickname,
               case when r.is_blocked then null::text else r.avatar_path end as avatar_path,
               r.moderation_status, r.is_public, r.visit_number, r.is_blocked,
               (select count(*)::integer from public.review_likes l where l.review_id = r.id) as like_count,
               exists (
                   select 1 from public.review_likes l where l.review_id = r.id and l.user_id = viewer
               ) as is_liked,
               (select count(*)::integer from public.shop_reviews a
                where a.user_id = r.user_id and a.is_public and a.moderation_status = 'published') as author_review_count
        from page r
    )
    select jsonb_build_object(
        'reviews', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc, p.id desc) from payload p), '[]'::jsonb),
        'next_created_at', case when (select count(*) from eligible) > 10
            then (select created_at from page order by created_at, id limit 1) end,
        'next_review_id', case when (select count(*) from eligible) > 10
            then (select id from page order by created_at, id limit 1) end
    ) into result;
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'review', r.review,
            'shop', case when s.id is not null then jsonb_build_object(
                'id', s.id,
                'name', s.name,
                'address', s.address,
                'lat', s.lat,
                'lng', s.lng,
                'kakao_place_url', s.kakao_place_url,
                'naver_place_url', s.naver_place_url,
                'waiting_provider', s.waiting_provider,
                'waiting_provider_url', s.waiting_provider_url,
                'business_hours_weekly', s.business_hours_weekly,
                'business_hours_break_times', s.business_hours_break_times,
                'business_hours_last_orders', s.business_hours_last_orders,
                'business_hours_notice', s.business_hours_notice,
                'business_hours_notice_type', s.business_hours_notice_type,
                'instagram_url', s.instagram_url,
                'instagram_profile_image_path', s.instagram_profile_image_path,
                'menu_category_ids', s.menu_category_ids,
                'is_visible', s.is_visible,
                'created_at', s.created_at,
                'updated_at', s.updated_at
            ) end
        ) order by r.ordinality
    ), '[]'::jsonb)
    into rows
    from jsonb_array_elements(result -> 'reviews') with ordinality as r(review, ordinality)
    left join public.ramen_shops s on s.id = (r.review ->> 'shop_id')::uuid;

    -- Never return a partial page if a shop cannot be read; preserve cursor/offset semantics.
    if exists (select 1 from jsonb_array_elements(rows) r where r -> 'shop' = 'null'::jsonb) then
        raise exception 'Review shop unavailable' using errcode = '42501';
    end if;
    return jsonb_set(result, '{reviews}', rows);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_popular_review_feed_page(p_like_count integer DEFAULT NULL::integer, p_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_review_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    viewer uuid := auth.uid();
    result jsonb;
begin
    if (p_created_at is null) <> (p_review_id is null)
       or (p_created_at is null) <> (p_like_count is null)
       or p_like_count < 0
       or (p_created_at is not null and not pg_catalog.isfinite(p_created_at)) then
        raise exception 'Invalid popular community cursor' using errcode = '22023';
    end if;

    with eligible as materialized (
        select r.*, p.nickname, p.avatar_path, likes.like_count,
               exists (
                   select 1 from public.user_blocks b
                   where b.blocker_id = viewer and b.blocked_id = r.user_id
               ) as is_blocked
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        cross join lateral (
            select count(*)::integer as like_count
            from public.review_likes l where l.review_id = r.id
        ) likes
        where r.is_public and r.moderation_status = 'published'
          and p.is_public and p.suspended_at is null
          and not exists (
              select 1 from public.account_deletion_requests d where d.user_id = r.user_id
          )
          and (p_created_at is null or (likes.like_count, r.created_at, r.id) < (p_like_count, p_created_at, p_review_id))
        order by likes.like_count desc, r.created_at desc, r.id desc
        limit 11
    ), page as materialized (
        select * from eligible order by like_count desc, created_at desc, id desc limit 10
    ), payload as (
        select r.id, r.shop_id,
               case when r.is_blocked then ''::text else r.body end as body,
               r.created_at,
               case when r.is_blocked then array[]::text[] else r.image_paths end as image_paths,
               r.user_id,
               case when r.is_blocked then ''::text else r.nickname end as nickname,
               case when r.is_blocked then null::text else r.avatar_path end as avatar_path,
               r.moderation_status, r.is_public, r.visit_number, r.is_blocked,
               r.like_count,
               exists (
                   select 1 from public.review_likes l where l.review_id = r.id and l.user_id = viewer
               ) as is_liked,
               (select count(*)::integer from public.shop_reviews a
                where a.user_id = r.user_id and a.is_public and a.moderation_status = 'published') as author_review_count,
               jsonb_build_object(
                   'id', s.id,
                   'name', s.name,
                   'address', s.address,
                   'lat', s.lat,
                   'lng', s.lng,
                   'kakao_place_url', s.kakao_place_url,
                   'naver_place_url', s.naver_place_url,
                   'waiting_provider', s.waiting_provider,
                   'waiting_provider_url', s.waiting_provider_url,
                   'business_hours_weekly', s.business_hours_weekly,
                   'business_hours_break_times', s.business_hours_break_times,
                   'business_hours_last_orders', s.business_hours_last_orders,
                   'business_hours_notice', s.business_hours_notice,
                   'business_hours_notice_type', s.business_hours_notice_type,
                   'instagram_url', s.instagram_url,
                   'instagram_profile_image_path', s.instagram_profile_image_path,
                   'menu_category_ids', s.menu_category_ids,
                   'is_visible', s.is_visible,
                   'created_at', s.created_at,
                   'updated_at', s.updated_at
               ) as shop
        from page r
        join public.ramen_shops s on s.id = r.shop_id
    )
    select jsonb_build_object(
        'reviews', coalesce((select jsonb_agg(jsonb_build_object('review', to_jsonb(p) - 'shop', 'shop', p.shop) order by p.like_count desc, p.created_at desc, p.id desc) from payload p), '[]'::jsonb),
        'next_like_count', case when (select count(*) from eligible) > 10
            then (select like_count from page order by like_count, created_at, id limit 1) end,
        'next_created_at', case when (select count(*) from eligible) > 10
            then (select created_at from page order by like_count, created_at, id limit 1) end,
        'next_review_id', case when (select count(*) from eligible) > 10
            then (select id from page order by like_count, created_at, id limit 1) end
    ) into result;
    return result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_blocked_review_feed_once(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
    select public.fetch_blocked_shop_review_once(r.id)
    from public.shop_reviews r
    join public.public_profiles p on p.user_id = r.user_id
    join public.ramen_shops s on s.id = r.shop_id and s.is_visible
    where auth.uid() is not null
      and r.id = p_review_id
      and r.is_public and r.moderation_status = 'published'
      and p.is_public and p.suspended_at is null
      and not exists (select 1 from public.account_deletion_requests d where d.user_id = r.user_id)
      and exists (
          select 1 from public.user_blocks b
          where b.blocker_id = auth.uid() and b.blocked_id = r.user_id
      );
$function$;


-- Check equivalent pages under the real API roles before removing the old names.
-- Any mismatch rolls back the function replacements and removals together.
do $verify$
declare
    original_role text := current_user;
    viewer uuid := (select user_id from public.public_profiles where suspended_at is null limit 1);
    api_role text;
    previous_page jsonb;
    current_page jsonb;
    previous_next jsonb;
    current_next jsonb;
begin
    foreach api_role in array array['anon', 'authenticated'] loop
        perform set_config('request.jwt.claim.sub',
            case when api_role = 'authenticated' then coalesce(viewer::text, '') else '' end, true);
        execute format('set local role %I', api_role);

        previous_page := public.fetch_community_reviews_page_v2();
        current_page := public.fetch_review_feed_page();
        if previous_page is distinct from current_page then
            raise exception 'Latest feed first page changed for %', api_role;
        end if;
        if previous_page ->> 'next_review_id' is not null then
            previous_next := public.fetch_community_reviews_page_v2(
                (previous_page ->> 'next_created_at')::timestamptz,
                (previous_page ->> 'next_review_id')::uuid);
            current_next := public.fetch_review_feed_page(
                (previous_page ->> 'next_created_at')::timestamptz,
                (previous_page ->> 'next_review_id')::uuid);
            if previous_next is distinct from current_next then
                raise exception 'Latest feed next page changed for %', api_role;
            end if;
        end if;

        previous_page := public.fetch_community_popular_reviews_page();
        current_page := public.fetch_popular_review_feed_page();
        if previous_page is distinct from current_page then
            raise exception 'Popular feed first page changed for %', api_role;
        end if;
        if previous_page ->> 'next_review_id' is not null then
            previous_next := public.fetch_community_popular_reviews_page(
                (previous_page ->> 'next_like_count')::integer,
                (previous_page ->> 'next_created_at')::timestamptz,
                (previous_page ->> 'next_review_id')::uuid);
            current_next := public.fetch_popular_review_feed_page(
                (previous_page ->> 'next_like_count')::integer,
                (previous_page ->> 'next_created_at')::timestamptz,
                (previous_page ->> 'next_review_id')::uuid);
            if previous_next is distinct from current_next then
                raise exception 'Popular feed next page changed for %', api_role;
            end if;
        end if;

        if api_role = 'authenticated' then
            if public.fetch_community_blocked_review_once(null)
                is distinct from public.fetch_blocked_review_feed_once(null) then
                raise exception 'Blocked feed result changed';
            end if;
        end if;
        execute format('set local role %I', original_role);
    end loop;
    perform set_config('request.jwt.claim.sub', '', true);
end;
$verify$;

-- These four endpoints were introduced after v1.1.14 and are absent from all
-- published app tags. Profile, moderation and shop-review endpoints stay intact.
-- RESTRICT is intentional: an unexpected dependency aborts this migration.
drop function public.fetch_community_reviews_page_v2(timestamptz, uuid) restrict;
drop function public.fetch_community_reviews_page(timestamptz, uuid) restrict;
drop function public.fetch_community_popular_reviews_page(integer, timestamptz, uuid) restrict;
drop function public.fetch_community_blocked_review_once(uuid) restrict;
