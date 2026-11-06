-- Add personal feed filters without altering existing feed RPCs.
create schema if not exists feed_private;
revoke all on schema feed_private from public, anon;
grant usage on schema feed_private to authenticated;

CREATE FUNCTION feed_private.fetch_filtered_review_feed_page(p_filter text, p_sort text DEFAULT 'latest'::text, p_like_count integer DEFAULT NULL::integer, p_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_review_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    viewer uuid := auth.uid();
    result jsonb;
begin
    if viewer is null or not exists (
        select 1 from public.public_profiles p
        where p.user_id = viewer and p.suspended_at is null
          and not exists (select 1 from public.account_deletion_requests d where d.user_id = viewer)
    ) then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if p_filter is null or p_filter not in ('saved_shops', 'following')
       or p_sort is null or p_sort not in ('latest', 'popular') then
        raise exception 'Invalid feed filter or sort' using errcode = '22023';
    end if;
    if (p_created_at is null) <> (p_review_id is null)
       or (p_sort = 'popular' and (p_created_at is null) <> (p_like_count is null))
       or (p_sort = 'latest' and p_like_count is not null)
       or p_like_count < 0
       or (p_created_at is not null and not pg_catalog.isfinite(p_created_at)) then
        raise exception 'Invalid filtered feed cursor' using errcode = '22023';
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
            from public.review_likes l where p_sort = 'popular' and l.review_id = r.id
        ) likes
        where r.is_public and r.moderation_status = 'published'
          and p.is_public and p.suspended_at is null
          and (
              (p_filter = 'saved_shops' and exists (
                  select 1 from public.user_shop_bookmarks b
                  where b.user_id = viewer and b.shop_id = r.shop_id
              ))
              or (p_filter = 'following' and exists (
                  select 1 from public.profile_follows f
                  where f.follower_id = viewer and f.followed_id = r.user_id and f.status = 'following'
              ))
          )
          and not exists (
              select 1 from public.account_deletion_requests d where d.user_id = r.user_id
          )
          and (p_created_at is null or (likes.like_count, r.created_at, r.id) < (case when p_sort = 'popular' then p_like_count else 0 end, p_created_at, p_review_id))
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
               r.like_count as sort_like_count,
               case when p_sort = 'popular' then r.like_count
                    else (select count(*)::integer from public.review_likes l where l.review_id = r.id)
               end as like_count,
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
        'reviews', coalesce((select jsonb_agg(jsonb_build_object('review', to_jsonb(p) - 'shop' - 'sort_like_count', 'shop', p.shop) order by p.sort_like_count desc, p.created_at desc, p.id desc) from payload p), '[]'::jsonb),
        'next_like_count', case when p_sort = 'popular' and (select count(*) from eligible) > 10
            then (select like_count from page order by like_count, created_at, id limit 1) end,
        'next_created_at', case when (select count(*) from eligible) > 10
            then (select created_at from page order by like_count, created_at, id limit 1) end,
        'next_review_id', case when (select count(*) from eligible) > 10
            then (select id from page order by like_count, created_at, id limit 1) end
    ) into result;
    return result;
end;
$function$;

revoke all on function feed_private.fetch_filtered_review_feed_page(text, text, integer, timestamptz, uuid) from public, anon;
grant execute on function feed_private.fetch_filtered_review_feed_page(text, text, integer, timestamptz, uuid) to authenticated;

create function public.fetch_filtered_review_feed_page(
    p_filter text,
    p_sort text default 'latest',
    p_like_count integer default null,
    p_created_at timestamptz default null,
    p_review_id uuid default null
)
returns jsonb
language sql
stable security invoker
set search_path = ''
as $$
    select feed_private.fetch_filtered_review_feed_page(p_filter, p_sort, p_like_count, p_created_at, p_review_id);
$$;
revoke all on function public.fetch_filtered_review_feed_page(text, text, integer, timestamptz, uuid) from public, anon;
grant execute on function public.fetch_filtered_review_feed_page(text, text, integer, timestamptz, uuid) to authenticated;
