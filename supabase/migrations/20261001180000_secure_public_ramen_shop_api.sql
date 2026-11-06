begin;

create or replace function public.project_public_ramen_shop(p_shop jsonb)
returns jsonb
language sql
immutable
security invoker
set search_path = ''
as $$
    select jsonb_build_object(
        'id', p_shop -> 'id',
        'name', p_shop -> 'name',
        'address', p_shop -> 'address',
        'lat', p_shop -> 'lat',
        'lng', p_shop -> 'lng',
        'kakao_place_url', p_shop -> 'kakao_place_url',
        'naver_place_url', p_shop -> 'naver_place_url',
        'business_hours_weekly', p_shop -> 'business_hours_weekly',
        'business_hours_break_times', p_shop -> 'business_hours_break_times',
        'business_hours_last_orders', p_shop -> 'business_hours_last_orders',
        'business_hours_notice', p_shop -> 'business_hours_notice',
        'business_hours_notice_type', p_shop -> 'business_hours_notice_type',
        'instagram_url', p_shop -> 'instagram_url',
        'instagram_profile_image_path', p_shop -> 'instagram_profile_image_path',
        'menu_category_ids', p_shop -> 'menu_category_ids',
        'created_at', p_shop -> 'created_at',
        'updated_at', p_shop -> 'updated_at'
    );
$$;

revoke all on function public.project_public_ramen_shop(jsonb) from public;
grant execute on function public.project_public_ramen_shop(jsonb) to anon, authenticated;

create or replace function public.fetch_public_ramen_shops_in_bounds(
    p_min_lat double precision,
    p_max_lat double precision,
    p_min_lng double precision,
    p_max_lng double precision
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if p_min_lat is null or p_max_lat is null or p_min_lng is null or p_max_lng is null
        or p_min_lat < -90 or p_max_lat > 90 or p_min_lng < -180 or p_max_lng > 180
        or p_min_lat >= p_max_lat or p_min_lng >= p_max_lng
        or p_max_lat - p_min_lat > 1.5 or p_max_lng - p_min_lng > 1.5 then
        raise exception using errcode = '22023', message = 'Invalid or oversized map bounds';
    end if;

    return query
    select public.project_public_ramen_shop(to_jsonb(shop))
    from public.ramen_shops shop
    where shop.is_visible
        and shop.lat between p_min_lat and p_max_lat
        and shop.lng between p_min_lng and p_max_lng
    order by shop.id
    limit 1000;
end;
$$;

create or replace function public.fetch_public_ramen_shops_by_ids(p_shop_ids uuid[])
returns setof jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if coalesce(cardinality(p_shop_ids), 0) > 100 then
        raise exception using errcode = '22023', message = 'Too many shop IDs';
    end if;

    return query
    select public.project_public_ramen_shop(to_jsonb(shop))
    from public.ramen_shops shop
    where shop.is_visible and shop.id = any(coalesce(p_shop_ids, array[]::uuid[]))
    order by shop.id;
end;
$$;

create or replace function public.search_public_ramen_shops(p_pattern text, p_limit integer)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select public.project_public_ramen_shop(to_jsonb(shop))
    from public.ramen_shops shop
    where shop.is_visible
        and coalesce(length(p_pattern), 0) between 3 and 512
        and (
            shop.name ilike p_pattern escape '\'
            or shop.address ilike p_pattern escape '\'
            or shop.business_hours_notice ilike p_pattern escape '\'
            or shop.kakao_place_url ilike p_pattern escape '\'
            or shop.naver_place_url ilike p_pattern escape '\'
        )
    order by shop.name, shop.id
    limit least(greatest(coalesce(p_limit, 1), 1), 50);
$$;

create or replace function public.fetch_public_shop_waiting_system(p_shop_id uuid)
returns table(waiting_provider text, waiting_provider_url text)
language sql
stable
security definer
set search_path = ''
as $$
    select shop.waiting_provider::text, shop.waiting_provider_url::text
    from public.ramen_shops shop
    where shop.id = p_shop_id and shop.is_visible
    limit 1;
$$;

revoke all on function public.fetch_public_ramen_shops_in_bounds(double precision, double precision, double precision, double precision) from public;
revoke all on function public.fetch_public_ramen_shops_by_ids(uuid[]) from public;
revoke all on function public.search_public_ramen_shops(text, integer) from public;
revoke all on function public.fetch_public_shop_waiting_system(uuid) from public;
grant execute on function public.fetch_public_ramen_shops_in_bounds(double precision, double precision, double precision, double precision) to anon, authenticated;
grant execute on function public.fetch_public_ramen_shops_by_ids(uuid[]) to anon, authenticated;
grant execute on function public.search_public_ramen_shops(text, integer) to anon, authenticated;
grant execute on function public.fetch_public_shop_waiting_system(uuid) to anon, authenticated;

create or replace function public.fetch_shop_detail_v2(p_shop_id uuid)
returns table(shop jsonb, like_count bigint, waiting_system jsonb, events jsonb, event_participants jsonb, operating_notice jsonb, menu_sections jsonb, menu_items jsonb)
language sql
stable
security definer
set search_path = ''
as $$
    select public.project_public_ramen_shop(to_jsonb(s)),
        coalesce((select counts.like_count from public.shop_bookmark_counts counts where counts.shop_id = s.id limit 1), 0)::bigint,
        (select to_jsonb(waiting) from public.shop_waiting_systems waiting where waiting.shop_id = s.id limit 1),
        coalesce((select jsonb_agg(to_jsonb(shop_event) order by shop_event.start_date, shop_event.id) from public.active_shop_events_v2 shop_event where shop_event.shop_context_id = s.id), '[]'::jsonb),
        coalesce((select jsonb_agg(to_jsonb(participant) order by participant.event_id, participant.shop_id) from public.shop_event_participants participant where participant.event_id in (select shop_event.id from public.active_shop_events_v2 shop_event where shop_event.shop_context_id = s.id)), '[]'::jsonb),
        (select to_jsonb(notice) from public.shop_operating_notices notice where notice.shop_id = s.id and (notice.end_date is null or notice.end_date >= (current_timestamp at time zone 'Asia/Seoul')::date) order by notice.notice_date desc, notice.id limit 1),
        coalesce((select jsonb_agg(to_jsonb(section) order by case when trim(section.title) = '상시메뉴' then 1 else 0 end, section.display_order, section.id) from public.shop_menu_sections section where section.shop_id = s.id and section.is_visible), '[]'::jsonb),
        coalesce((select jsonb_agg(to_jsonb(item) order by item.display_order, item.id) from public.visible_shop_menu_items item where item.shop_id = s.id), '[]'::jsonb)
    from public.ramen_shops s where s.id = p_shop_id and s.is_visible;
$$;

revoke all on function public.fetch_shop_detail_v2(uuid) from public;
grant execute on function public.fetch_shop_detail_v2(uuid) to anon, authenticated;

create or replace view public.active_events_v2 with (security_invoker = false) as
select event.id, event.event_type, event.title, event.description, event.start_date, event.end_date, event.source_url,
  public.event_is_today_on(event.event_type, event.start_date, event.end_date, (current_timestamp at time zone 'Asia/Seoul')::date) as is_today,
  event.shop_id is not null as is_venue,
  case when venue.id is null then null else public.project_public_ramen_shop(to_jsonb(venue)) end as venue_shop,
  coalesce((select jsonb_agg(public.project_public_ramen_shop(to_jsonb(collaborator_shop)) order by participant.created_at)
    from public.shop_event_participants participant join public.ramen_shops collaborator_shop on collaborator_shop.id = participant.shop_id
    where participant.event_id = event.id and participant.shop_id is distinct from event.shop_id), '[]'::jsonb) as collaborator_shops,
  coalesce((select jsonb_agg(jsonb_build_object('name', participant.external_name, 'instagram_url', participant.external_instagram_url) order by participant.created_at)
    from public.shop_event_participants participant where participant.event_id = event.id and participant.shop_id is null), '[]'::jsonb) as external_participants,
  event.waiting_method, event.waiting_url, event.cancelled_dates,
  (current_timestamp at time zone 'Asia/Seoul')::date = any(event.cancelled_dates) as is_cancelled_today,
  event.image_paths, event.sold_out_dates,
  (current_timestamp at time zone 'Asia/Seoul')::date = any(event.sold_out_dates) as is_sold_out_today,
  case when (current_timestamp at time zone 'Asia/Seoul')::date = any(event.cancelled_dates) then event.cancellation_reason else null end as cancellation_reason,
  event.cancellation_source_url, event.venue_name, event.venue_instagram_url, event.venue_naver_map_url,
  event.venue_kakao_map_url, to_jsonb(external_venue.*) as external_venue
from public.shop_events event
left join public.ramen_shops venue on venue.id = event.shop_id
left join public.external_venues external_venue on external_venue.id = event.external_venue_id
where event.event_type = any(array['collab', 'popup', 'limited_menu', 'summer_limited', 'new_menu', 'store_renewal'])
  and public.event_is_active_on(event.event_type, event.start_date, event.end_date, (current_timestamp at time zone 'Asia/Seoul')::date)
order by event.created_at desc, event.id desc;

create or replace view public.active_shop_events_v2 with (security_invoker = false) as
select event_context.shop_context_id, coalesce(event_context.shop_context_id = event.shop_id, false) as is_venue,
  active.id, active.event_type, active.title, active.description, active.start_date, active.end_date, active.source_url,
  active.is_today, active.venue_shop, active.collaborator_shops, active.external_participants,
  active.waiting_method, active.waiting_url, active.cancelled_dates, active.is_cancelled_today,
  active.image_paths, active.sold_out_dates, active.is_sold_out_today, active.cancellation_reason,
  active.cancellation_source_url, active.venue_name, active.venue_instagram_url,
  active.venue_naver_map_url, active.venue_kakao_map_url, active.external_venue
from public.active_events_v2 active
join public.shop_events event on event.id = active.id
cross join lateral (
  select event.shop_id as shop_context_id
  union
  select participant.shop_id from public.shop_event_participants participant
  where participant.event_id = event.id and participant.shop_id is not null
) event_context
where event_context.shop_context_id is not null
order by active.start_date;

grant select on public.active_events_v2, public.active_shop_events_v2 to anon, authenticated;

commit;
