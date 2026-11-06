-- Additive API versions: keep all existing functions and permissions unchanged.
-- Existing RPCs own review visibility, block masking, ordering and pagination.

create function public.fetch_community_reviews_page_v2(p_created_at timestamptz default null, p_review_id uuid default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $function$
declare
    page jsonb;
    rows jsonb;
begin
    page := public.fetch_community_reviews_page(p_created_at, p_review_id);
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
    from jsonb_array_elements(page -> 'reviews') with ordinality as r(review, ordinality)
    left join public.ramen_shops s on s.id = (r.review ->> 'shop_id')::uuid;

    -- Never return a partial page if a shop cannot be read; preserve cursor/offset semantics.
    if exists (select 1 from jsonb_array_elements(rows) r where r -> 'shop' = 'null'::jsonb) then
        raise exception 'Review shop unavailable' using errcode = '42501';
    end if;
    return jsonb_set(page, '{reviews}', rows);
end;
$function$;

create function public.fetch_profile_reviews_page_v3(p_user_id uuid, p_offset bigint default 0)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $function$
declare
    page jsonb;
    rows jsonb;
begin
    page := public.fetch_profile_reviews_page_v2(p_user_id, p_offset);
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
    from jsonb_array_elements(page -> 'reviews') with ordinality as r(review, ordinality)
    left join public.ramen_shops s on s.id = (r.review ->> 'shop_id')::uuid;

    -- Never return a partial page if a shop cannot be read; preserve cursor/offset semantics.
    if exists (select 1 from jsonb_array_elements(rows) r where r -> 'shop' = 'null'::jsonb) then
        raise exception 'Review shop unavailable' using errcode = '42501';
    end if;
    return jsonb_set(page, '{reviews}', rows);
end;
$function$;

revoke all on function public.fetch_community_reviews_page_v2(timestamptz, uuid) from public;
revoke all on function public.fetch_profile_reviews_page_v3(uuid, bigint) from public;
grant execute on function public.fetch_community_reviews_page_v2(timestamptz, uuid) to anon, authenticated;
grant execute on function public.fetch_profile_reviews_page_v3(uuid, bigint) to anon, authenticated;
