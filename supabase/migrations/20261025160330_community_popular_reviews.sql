-- Add popular ordering without changing any existing feed endpoint.
create function public.fetch_community_popular_reviews_page(
    p_like_count integer default null,
    p_created_at timestamptz default null,
    p_review_id uuid default null
)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $function$
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

revoke all on function public.fetch_community_popular_reviews_page(integer, timestamptz, uuid) from public;
grant execute on function public.fetch_community_popular_reviews_page(integer, timestamptz, uuid) to anon, authenticated;
