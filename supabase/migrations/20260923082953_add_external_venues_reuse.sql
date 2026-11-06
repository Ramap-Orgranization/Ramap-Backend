begin;

do $$
begin
    if exists (select 1 from public.shop_events where shop_id is null) then
        raise exception 'external venue migration requires no existing external shop_events';
    end if;
end;
$$;

create table public.external_venues (
    id uuid primary key default gen_random_uuid(),
    name text not null check (length(trim(name)) > 0),
    address text,
    image_path text check (image_path is null or (image_path ~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$' and image_path !~ '(^|/)\.\.(/|$)')),
    instagram_url text check (instagram_url is null or (instagram_url ~ '^https://www\.instagram\.com/[A-Za-z0-9._]+/$' and instagram_url !~ '^https://www\.instagram\.com/(p|reel)/')),
    naver_map_url text check (naver_map_url is null or naver_map_url ~ '^https://map\.naver\.com/(p/entry|v5/entry)/place/[0-9]+(\?[^#[:space:]]*)?$' or naver_map_url ~ '^https://naver\.me/[A-Za-z0-9]+$'),
    kakao_map_url text check (kakao_map_url is null or kakao_map_url ~ '^https://place\.map\.kakao\.com/[0-9]+$' or kakao_map_url ~ '^https://map\.kakao\.com/link/map/[0-9]+$'),
    created_at timestamptz not null default now()
);

alter table public.external_venues enable row level security;
revoke all on public.external_venues from anon, authenticated;
grant select on public.external_venues to anon, authenticated;
create policy "External venues are publicly readable"
    on public.external_venues for select to anon, authenticated using (true);

alter table public.shop_events
    add column external_venue_id uuid references public.external_venues(id),
    drop constraint shop_events_venue_check,
    add constraint shop_events_venue_check check (
        (shop_id is not null and external_venue_id is null and venue_name is null and venue_instagram_url is null and venue_naver_map_url is null and venue_kakao_map_url is null)
        or (
            shop_id is null
            and external_venue_id is not null
            and venue_name is not null
            and length(trim(venue_name)) > 0
            and (venue_instagram_url is null or (venue_instagram_url ~ '^https://www\.instagram\.com/[A-Za-z0-9._]+/$' and venue_instagram_url !~ '^https://www\.instagram\.com/(p|reel)/'))
            and (venue_naver_map_url is null or venue_naver_map_url ~ '^https://map\.naver\.com/(p/entry|v5/entry)/place/[0-9]+(\?[^#[:space:]]*)?$' or venue_naver_map_url ~ '^https://naver\.me/[A-Za-z0-9]+$')
            and (venue_kakao_map_url is null or venue_kakao_map_url ~ '^https://place\.map\.kakao\.com/[0-9]+$' or venue_kakao_map_url ~ '^https://map\.kakao\.com/link/map/[0-9]+$')
        )
    );

create index shop_events_external_venue_id_index on public.shop_events(external_venue_id) where external_venue_id is not null;
drop index if exists public.shop_events_external_venue_source_item_unique;
create unique index shop_events_external_venue_id_source_item_unique
    on public.shop_events(source_url, title, start_date, external_venue_id)
    where external_venue_id is not null;
create unique index external_venues_naver_map_url_unique on public.external_venues(naver_map_url) where naver_map_url is not null;
create unique index external_venues_kakao_map_url_unique on public.external_venues(kakao_map_url) where kakao_map_url is not null;

create or replace view public.active_events_v2 with (security_invoker = true) as
select event.id, event.event_type, event.title, event.description, event.start_date, event.end_date, event.source_url,
  event_is_today_on(event.event_type, event.start_date, event.end_date, (current_timestamp at time zone 'Asia/Seoul')::date) as is_today,
  event.shop_id is not null as is_venue, to_jsonb(venue.*) as venue_shop,
  coalesce((select jsonb_agg(to_jsonb(collaborator_shop.*) order by participant.created_at) from public.shop_event_participants participant join public.ramen_shops collaborator_shop on collaborator_shop.id = participant.shop_id where participant.event_id = event.id and participant.shop_id is distinct from event.shop_id), '[]'::jsonb) as collaborator_shops,
  coalesce((select jsonb_agg(jsonb_build_object('name', participant.external_name, 'instagram_url', participant.external_instagram_url) order by participant.created_at) from public.shop_event_participants participant where participant.event_id = event.id and participant.shop_id is null), '[]'::jsonb) as external_participants,
  event.waiting_method, event.waiting_url, event.cancelled_dates, (current_timestamp at time zone 'Asia/Seoul')::date = any(event.cancelled_dates) as is_cancelled_today, event.image_paths, event.sold_out_dates, (current_timestamp at time zone 'Asia/Seoul')::date = any(event.sold_out_dates) as is_sold_out_today,
  case when (current_timestamp at time zone 'Asia/Seoul')::date = any(event.cancelled_dates) then event.cancellation_reason else null end as cancellation_reason, event.cancellation_source_url,
  event.venue_name, event.venue_instagram_url, event.venue_naver_map_url, event.venue_kakao_map_url, to_jsonb(external_venue.*) as external_venue
from public.shop_events event
left join public.ramen_shops venue on venue.id = event.shop_id
left join public.external_venues external_venue on external_venue.id = event.external_venue_id
where event.event_type = any(array['collab', 'popup', 'limited_menu', 'summer_limited', 'new_menu', 'store_renewal']) and event_is_active_on(event.event_type, event.start_date, event.end_date, (current_timestamp at time zone 'Asia/Seoul')::date)
order by event.created_at desc, event.id desc;

create or replace view public.active_shop_events_v2 with (security_invoker = true) as
select event_context.shop_context_id, event_context.shop_context_id = event.shop_id as is_venue,
  active.id, active.event_type, active.title, active.description, active.start_date, active.end_date, active.source_url, active.is_today, active.venue_shop, active.collaborator_shops, active.external_participants,
  active.waiting_method, active.waiting_url, active.cancelled_dates, active.is_cancelled_today, active.image_paths, active.sold_out_dates, active.is_sold_out_today, active.cancellation_reason, active.cancellation_source_url,
  active.venue_name, active.venue_instagram_url, active.venue_naver_map_url, active.venue_kakao_map_url, active.external_venue
from public.active_events_v2 active
join public.shop_events event on event.id = active.id
cross join lateral (select event.shop_id as shop_context_id union select participant.shop_id from public.shop_event_participants participant where participant.event_id = event.id and participant.shop_id is not null) event_context
order by active.start_date;

revoke all on function public.fetch_shop_detail_v2(uuid) from public;
grant execute on function public.fetch_shop_detail_v2(uuid) to anon, authenticated;

commit;
