create or replace view public.active_shop_events_v2 with (security_invoker = true) as
select event_context.shop_context_id, coalesce(event_context.shop_context_id = event.shop_id, false) as is_venue,
  active.id, active.event_type, active.title, active.description, active.start_date, active.end_date, active.source_url, active.is_today, active.venue_shop, active.collaborator_shops, active.external_participants,
  active.waiting_method, active.waiting_url, active.cancelled_dates, active.is_cancelled_today, active.image_paths, active.sold_out_dates, active.is_sold_out_today, active.cancellation_reason, active.cancellation_source_url,
  active.venue_name, active.venue_instagram_url, active.venue_naver_map_url, active.venue_kakao_map_url, active.external_venue
from public.active_events_v2 active
join public.shop_events event on event.id = active.id
cross join lateral (
  select event.shop_id as shop_context_id
  union
  select participant.shop_id
  from public.shop_event_participants participant
  where participant.event_id = event.id and participant.shop_id is not null
) event_context
where event_context.shop_context_id is not null
order by active.start_date;
