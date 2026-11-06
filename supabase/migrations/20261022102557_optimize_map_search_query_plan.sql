-- A separate map API keeps the URL-based report lookup compatible with old clients.
create or replace function public.search_map_ramen_shops(
    p_query text,
    p_lat double precision default null,
    p_lng double precision default null,
    p_limit integer default 50
)
returns setof jsonb
language plpgsql
stable
security invoker
set search_path = ''
set jit = 'off'
as $$
declare
    query_text text := lower(regexp_replace(btrim(normalize(coalesce(p_query, ''), NFKC)), '[[:space:]]+', ' ', 'g'));
    query_key text := replace(query_text, ' ', '');
begin
    if length(query_text) not between 1 and 100 then
        return;
    end if;
    if (p_lat is null) <> (p_lng is null)
        or (p_lat is not null and not (p_lat between -90 and 90 and p_lng between -180 and 180)) then
        raise exception using errcode = '22023', message = 'Invalid search coordinates';
    end if;

    return query
    with region_aliases(alias, region) as (values
        ('서울', '서울'), ('서울시', '서울'), ('서울특별시', '서울'),
        ('부산', '부산'), ('부산시', '부산'), ('부산광역시', '부산'),
        ('대구', '대구'), ('대구시', '대구'), ('대구광역시', '대구'),
        ('인천', '인천'), ('인천시', '인천'), ('인천광역시', '인천'),
        ('광주', '광주'), ('광주시', '광주'), ('광주광역시', '광주'),
        ('대전', '대전'), ('대전시', '대전'), ('대전광역시', '대전'),
        ('울산', '울산'), ('울산시', '울산'), ('울산광역시', '울산'),
        ('세종', '세종'), ('세종시', '세종'), ('세종특별자치시', '세종'),
        ('경기', '경기'), ('경기도', '경기'),
        ('강원', '강원'), ('강원도', '강원'), ('강원특별자치도', '강원'),
        ('충북', '충북'), ('충청북도', '충북'), ('충남', '충남'), ('충청남도', '충남'),
        ('전북', '전북'), ('전라북도', '전북'), ('전북특별자치도', '전북'),
        ('전남', '전남'), ('전라남도', '전남'),
        ('경북', '경북'), ('경상북도', '경북'), ('경남', '경남'), ('경상남도', '경남'),
        ('제주', '제주'), ('제주도', '제주'), ('제주특별자치도', '제주')
    ), province_keys as materialized (
        select a.alias, array_agg(b.alias) as aliases
        from region_aliases a join region_aliases b on a.region = b.region
        group by a.alias
    ), query_parts as materialized (
        select left(query_key, boundary) as first_key, substr(query_key, boundary + 1) as second_key
        from generate_series(2, length(query_key) - 2) boundary
    ), normalized as materialized (
        select shop.id, shop.name, shop.address, shop.lat, shop.lng,
            regexp_replace(lower(normalize(shop.name, NFKC)), '[[:space:]]+', '', 'g') as name_key,
            regexp_replace(lower(normalize(shop.address, NFKC)), '[[:space:]]+', '', 'g') as address_key,
            regexp_split_to_array(btrim(shop.address), '[[:space:]]+') as address_parts
        from public.ramen_shops shop
        where shop.is_visible
    ), searchable as materialized (
        select shop.*,
            coalesce(province.aliases, '{}'::text[]) || array(
                select district from unnest(address_parts[2:4]) district
                where district ~ '(시|군|구|읍|면|동|리)$'
            ) || array(
                select regexp_replace(district, '(시|군|구|읍|면|동|리)$', '')
                from unnest(address_parts[2:4]) district
                where district ~ '(시|군|구|읍|면|동|리)$'
            ) as region_keys
        from normalized shop
        left join province_keys province on province.alias = shop.address_parts[1]
    ), ranked as materialized (
        select shop.*,
            case
                when name_key = query_key then 0
                when left(name_key, length(query_key)) = query_key then 1
                when strpos(name_key, query_key) > 0 then 2
                -- Words must each match literally. Name and location may be in either order.
                when (position(' ' in query_text) > 0
                    and not exists (
                        select 1 from unnest(string_to_array(query_text, ' ')) token
                        where length(token) < 2 or not (
                            strpos(name_key, token) > 0 or strpos(address_key, token) > 0 or token = any(region_keys)
                        )
                    ) and exists (
                        select 1 from unnest(string_to_array(query_text, ' ')) token where strpos(name_key, token) > 0
                    ) and (
                        exists (select 1 from unnest(string_to_array(query_text, ' ')) token
                            where strpos(address_key, token) > 0 or token = any(region_keys))
                        or exists (
                            select 1 from unnest(string_to_array(query_text, ' ')) with ordinality a(token, ordinal)
                            join unnest(string_to_array(query_text, ' ')) with ordinality b(token, ordinal) on a.ordinal < b.ordinal
                            where strpos(name_key, a.token) > strpos(name_key, b.token)
                        )
                    )) or exists (
                        select 1 from query_parts
                        where (first_key = any(region_keys) and strpos(name_key, second_key) > 0)
                           or (second_key = any(region_keys) and strpos(name_key, first_key) > 0)
                    ) then 3
                when query_key = any(region_keys) then 4
                when strpos(address_key, query_key) > 0 then 5
                else 6
            end as match_rank,
            case when p_lat is not null then 12742000.0 * asin(least(1.0, sqrt(
                power(sin(radians(shop.lat::double precision - p_lat) / 2), 2) +
                cos(radians(p_lat)) * cos(radians(shop.lat::double precision)) *
                power(sin(radians(shop.lng::double precision - p_lng) / 2), 2)
            ))) end as distance_meters
        from searchable shop
    ), selected as (
        select id, match_rank, distance_meters, name_key from ranked
        where match_rank < 6 and (length(query_key) > 1 or match_rank = 0)
        order by match_rank, distance_meters nulls last, name_key collate "C", id
        limit least(greatest(coalesce(p_limit, 50), 1), 50)
    )
    select jsonb_build_object(
        'id', id, 'name', name, 'address', address, 'lat', lat, 'lng', lng,
        'kakao_place_url', kakao_place_url, 'naver_place_url', naver_place_url,
        'business_hours_weekly', business_hours_weekly,
        'business_hours_break_times', business_hours_break_times,
        'business_hours_last_orders', business_hours_last_orders,
        'business_hours_notice', business_hours_notice,
        'business_hours_notice_type', business_hours_notice_type,
        'instagram_url', instagram_url, 'instagram_profile_image_path', instagram_profile_image_path,
        'menu_category_ids', menu_category_ids, 'created_at', created_at, 'updated_at', updated_at
    )
    from selected join public.ramen_shops shop using (id)
    order by match_rank, distance_meters nulls last, name_key collate "C", id;
end;
$$;

revoke all on function public.search_map_ramen_shops(text, double precision, double precision, integer) from public;
grant execute on function public.search_map_ramen_shops(text, double precision, double precision, integer) to anon, authenticated;
