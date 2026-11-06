-- Operating notices are queried nationwide without region metadata.
create or replace function public.fetch_operating_notice_feed(p_today date)
returns jsonb
language sql stable security invoker set search_path = ''
as $function$
    select jsonb_build_object(
        'reference_date', p_today,
        'items', coalesce(jsonb_agg(jsonb_build_object(
            'notice', to_jsonb(notice),
            'shop', jsonb_build_object(
                'id', shops.id, 'name', shops.name,
                'lat', shops.lat, 'lng', shops.lng,
                'kakao_place_url', shops.kakao_place_url, 'naver_place_url', shops.naver_place_url,
                'instagram_url', shops.instagram_url, 'instagram_profile_image_path', shops.instagram_profile_image_path,
                'menu_category_ids', shops.menu_category_ids, 'created_at', shops.created_at, 'updated_at', shops.updated_at,
                'business_hours_weekly', shops.business_hours_weekly,
                'business_hours_break_times', shops.business_hours_break_times,
                'business_hours_last_orders', shops.business_hours_last_orders,
                'business_hours_notice', shops.business_hours_notice,
                'business_hours_notice_type', shops.business_hours_notice_type
            )
        ) order by notice.notice_date, shops.name, shops.id, notice.id), '[]'::jsonb)
    )
    from public.shop_operating_notices notice
    join public.ramen_shops shops on shops.id = notice.shop_id
    where shops.is_visible = true
      and (notice.end_date is null or notice.end_date >= p_today)
      and p_today is not null;
$function$;
revoke all on function public.fetch_operating_notice_feed(date) from public;
grant execute on function public.fetch_operating_notice_feed(date) to anon, authenticated;
notify pgrst, 'reload schema';
