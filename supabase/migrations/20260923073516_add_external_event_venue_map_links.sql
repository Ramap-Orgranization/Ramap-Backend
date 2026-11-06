alter table public.shop_events
    add column venue_naver_map_url text,
    add column venue_kakao_map_url text;

alter table public.shop_events
    drop constraint shop_events_venue_check,
    add constraint shop_events_venue_check check (
        (shop_id is not null and venue_name is null and venue_instagram_url is null and venue_naver_map_url is null and venue_kakao_map_url is null)
        or (
            shop_id is null
            and length(trim(venue_name)) > 0
            and (
                venue_instagram_url is null
                or venue_instagram_url ~ '^https://www\.instagram\.com/[A-Za-z0-9._]+/$'
            )
            and (
                venue_naver_map_url is null
                or venue_naver_map_url ~ '^https://map\.naver\.com/(p/entry|v5/entry)/place/[0-9]+(\?[^#[:space:]]*)?$'
                or venue_naver_map_url ~ '^https://naver\.me/[A-Za-z0-9]+$'
            )
            and (
                venue_kakao_map_url is null
                or venue_kakao_map_url ~ '^https://place\.map\.kakao\.com/[0-9]+$'
                or venue_kakao_map_url ~ '^https://map\.kakao\.com/link/map/[0-9]+$'
            )
        )
    );

create or replace view public.active_events_v2 with (security_invoker = true) as
select event.id, event.event_type, event.title, event.description, event.start_date, event.end_date, event.source_url,
  event_is_today_on(event.event_type, event.start_date, event.end_date, (current_timestamp at time zone 'Asia/Seoul')::date) as is_today,
  event.shop_id is not null as is_venue, to_jsonb(venue.*) as venue_shop,
  coalesce((select jsonb_agg(to_jsonb(collaborator_shop.*) order by participant.created_at) from public.shop_event_participants participant join public.ramen_shops collaborator_shop on collaborator_shop.id = participant.shop_id where participant.event_id = event.id and participant.shop_id is distinct from event.shop_id), '[]'::jsonb) as collaborator_shops,
  coalesce((select jsonb_agg(jsonb_build_object('name', participant.external_name, 'instagram_url', participant.external_instagram_url) order by participant.created_at) from public.shop_event_participants participant where participant.event_id = event.id and participant.shop_id is null), '[]'::jsonb) as external_participants,
  event.waiting_method, event.waiting_url, event.cancelled_dates, (current_timestamp at time zone 'Asia/Seoul')::date = any(event.cancelled_dates) as is_cancelled_today, event.image_paths, event.sold_out_dates, (current_timestamp at time zone 'Asia/Seoul')::date = any(event.sold_out_dates) as is_sold_out_today,
  case when (current_timestamp at time zone 'Asia/Seoul')::date = any(event.cancelled_dates) then event.cancellation_reason else null end as cancellation_reason, event.cancellation_source_url,
  event.venue_name, event.venue_instagram_url, event.venue_naver_map_url, event.venue_kakao_map_url
from public.shop_events event left join public.ramen_shops venue on venue.id = event.shop_id
where event.event_type = any(array['collab', 'popup', 'limited_menu', 'summer_limited', 'new_menu', 'store_renewal']) and event_is_active_on(event.event_type, event.start_date, event.end_date, (current_timestamp at time zone 'Asia/Seoul')::date)
order by event.created_at desc, event.id desc;

create or replace view public.active_shop_events_v2 with (security_invoker = true) as
select event_context.shop_context_id, event_context.shop_context_id = event.shop_id as is_venue,
  active.id, active.event_type, active.title, active.description, active.start_date, active.end_date, active.source_url, active.is_today, active.venue_shop, active.collaborator_shops, active.external_participants,
  active.waiting_method, active.waiting_url, active.cancelled_dates, active.is_cancelled_today, active.image_paths, active.sold_out_dates, active.is_sold_out_today, active.cancellation_reason, active.cancellation_source_url,
  active.venue_name, active.venue_instagram_url, active.venue_naver_map_url, active.venue_kakao_map_url
from public.active_events_v2 active
join public.shop_events event on event.id = active.id
cross join lateral (select event.shop_id as shop_context_id union select participant.shop_id from public.shop_event_participants participant where participant.event_id = event.id and participant.shop_id is not null) event_context
order by active.start_date;

create or replace function public.fetch_shop_detail_v2(p_shop_id uuid)
returns table(shop jsonb, like_count bigint, waiting_system jsonb, events jsonb, event_participants jsonb, operating_notice jsonb, menu_sections jsonb, menu_items jsonb)
language sql stable set search_path to '' as $$
    select to_jsonb(s), coalesce((select counts.like_count from public.shop_bookmark_counts counts where counts.shop_id = s.id limit 1), 0)::bigint,
        (select to_jsonb(waiting) from public.shop_waiting_systems waiting where waiting.shop_id = s.id limit 1),
        coalesce((select jsonb_agg(to_jsonb(shop_event) order by shop_event.start_date, shop_event.id) from public.active_shop_events_v2 shop_event where shop_event.shop_context_id = s.id), '[]'::jsonb),
        coalesce((select jsonb_agg(to_jsonb(participant) order by participant.event_id, participant.shop_id) from public.shop_event_participants participant where participant.event_id in (select shop_event.id from public.active_shop_events_v2 shop_event where shop_event.shop_context_id = s.id)), '[]'::jsonb),
        (select to_jsonb(notice) from public.shop_operating_notices notice where notice.shop_id = s.id and (notice.end_date is null or notice.end_date >= (current_timestamp at time zone 'Asia/Seoul')::date) order by notice.notice_date desc, notice.id limit 1),
        coalesce((select jsonb_agg(to_jsonb(section) order by case when trim(section.title) = '상시메뉴' then 1 else 0 end, section.display_order, section.id) from public.shop_menu_sections section where section.shop_id = s.id and section.is_visible), '[]'::jsonb),
        coalesce((select jsonb_agg(to_jsonb(item) order by item.display_order, item.id) from public.visible_shop_menu_items item where item.shop_id = s.id), '[]'::jsonb)
    from public.shops s where s.id = p_shop_id;
$$;

grant execute on function public.fetch_shop_detail_v2(uuid) to anon, authenticated;
