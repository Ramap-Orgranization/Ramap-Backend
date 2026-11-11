create function public.fetch_onboarding_shop_suggestions(
    p_cursor text default null,
    p_limit integer default 20
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
    -- Keep the seed and last shop ID in the cursor so later pages use the same order.
    with request as materialized (
        select
            coalesce(split_part(p_cursor, ':', 1)::uuid, gen_random_uuid()) as seed,
            split_part(p_cursor, ':', 2)::uuid as after_id,
            least(greatest(coalesce(p_limit, 20), 1), 50) as page_size
    ), candidates as (
        select shop.id, md5(request.seed::text || shop.id::text)::uuid as sort_key
        from public.ramen_shops shop
        cross join request
        where shop.is_visible
            and (
                request.after_id is null
                or (md5(request.seed::text || shop.id::text)::uuid, shop.id)
                    > (md5(request.seed::text || request.after_id::text)::uuid, request.after_id)
            )
        order by sort_key, shop.id
        limit (select page_size + 1 from request)
    ), page as (
        select id, row_number() over (order by sort_key, id) as position
        from candidates
    )
    select jsonb_build_object(
        'shops', coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'id', shop.id,
                    'name', shop.name,
                    'address', shop.address,
                    'lat', shop.lat,
                    'lng', shop.lng,
                    'kakao_place_url', shop.kakao_place_url,
                    'naver_place_url', shop.naver_place_url,
                    'business_hours_weekly', shop.business_hours_weekly,
                    'business_hours_break_times', shop.business_hours_break_times,
                    'business_hours_last_orders', shop.business_hours_last_orders,
                    'business_hours_notice', shop.business_hours_notice,
                    'business_hours_notice_type', shop.business_hours_notice_type,
                    'instagram_url', shop.instagram_url,
                    'instagram_profile_image_path', shop.instagram_profile_image_path,
                    'menu_category_ids', shop.menu_category_ids,
                    'created_at', shop.created_at,
                    'updated_at', shop.updated_at
                ) order by page.position
            ) filter (where page.position <= request.page_size),
            '[]'::jsonb
        ),
        'next_cursor', case when count(page.id) > request.page_size then
            request.seed::text || ':' || max(page.id::text) filter (where page.position = request.page_size)
        end
    )
    from request
    left join page on true
    left join public.ramen_shops shop on shop.id = page.id
    group by request.seed, request.page_size;
$$;

revoke all on function public.fetch_onboarding_shop_suggestions(text, integer) from public;
grant execute on function public.fetch_onboarding_shop_suggestions(text, integer) to anon, authenticated;

notify pgrst, 'reload schema';
