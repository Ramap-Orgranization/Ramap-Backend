-- Exclude display addresses; retain normalized region fields for filtering.
create or replace function public.fetch_operating_notice_feed(p_today date)
returns jsonb
language sql stable security invoker set search_path = ''
as $function$
    with visible_shop_areas as (
        select shops.*,
               case split_part(btrim(shops.address), ' ', 1)
                   when '서울' then 'SEOUL'
                   when '서울특별시' then 'SEOUL'
                   when '부산' then 'BUSAN'
                   when '부산광역시' then 'BUSAN'
                   when '대구' then 'DAEGU'
                   when '대구광역시' then 'DAEGU'
                   when '인천' then 'INCHEON'
                   when '인천광역시' then 'INCHEON'
                   when '광주' then 'GWANGJU'
                   when '광주광역시' then 'GWANGJU'
                   when '대전' then 'DAEJEON'
                   when '대전광역시' then 'DAEJEON'
                   when '울산' then 'ULSAN'
                   when '울산광역시' then 'ULSAN'
                   when '세종' then 'SEJONG'
                   when '세종특별자치시' then 'SEJONG'
                   when '경기' then 'GYEONGGI'
                   when '경기도' then 'GYEONGGI'
                   when '충북' then 'CHUNGBUK'
                   when '충청북도' then 'CHUNGBUK'
                   when '충남' then 'CHUNGNAM'
                   when '충청남도' then 'CHUNGNAM'
                   when '전남' then 'JEONNAM'
                   when '전라남도' then 'JEONNAM'
                   when '전남광주통합특별시' then 'JEONNAM'
                   when '경북' then 'GYEONGBUK'
                   when '경상북도' then 'GYEONGBUK'
                   when '경남' then 'GYEONGNAM'
                   when '경상남도' then 'GYEONGNAM'
                   when '강원' then 'GANGWON'
                   when '강원도' then 'GANGWON'
                   when '강원특별자치도' then 'GANGWON'
                   when '전북' then 'JEONBUK'
                   when '전라북도' then 'JEONBUK'
                   when '전북특별자치도' then 'JEONBUK'
                   when '제주' then 'JEJU'
                   when '제주도' then 'JEJU'
                   when '제주특별자치도' then 'JEJU'
                   else null
               end as area,
               case when split_part(btrim(shops.address), ' ', 2) ~ '(시|군|구)$'
                    then split_part(btrim(shops.address), ' ', 2) else null end as sigungu
        from public.ramen_shops shops where shops.is_visible = true
    )
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
            ),
            'area', shops.area,
            'sigungu', case when shops.area is null or shops.area = 'SEJONG' then null else shops.sigungu end
        ) order by notice.notice_date, shops.name, shops.id, notice.id), '[]'::jsonb)
    )
    from public.shop_operating_notices notice
    join visible_shop_areas shops on shops.id = notice.shop_id
    where (notice.end_date is null or notice.end_date >= p_today)
      and p_today is not null;
$function$;
revoke all on function public.fetch_operating_notice_feed(date) from public;
grant execute on function public.fetch_operating_notice_feed(date) to anon, authenticated;
notify pgrst, 'reload schema';
