set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- Existing clients keep the v2 aggregate contract. New clients query menus separately.
create or replace function public.fetch_shop_detail_v3(p_shop_id uuid)
returns table(shop jsonb, like_count bigint, events jsonb, event_participants jsonb, operating_notice jsonb)
language sql stable security invoker
set search_path = ''
as $function$
    select
        to_jsonb(s),
        coalesce((select counts.like_count from public.shop_bookmark_counts counts where counts.shop_id = s.id limit 1), 0)::bigint,
        coalesce((
            select jsonb_agg(event_row.event order by event_row.event->>'start_date', event_row.event->>'id')
            from public.fetch_active_shop_events(s.id) as event_row(event)
        ), '[]'::jsonb),
        coalesce((
            select jsonb_agg(to_jsonb(participant) order by participant.event_id, participant.shop_id)
            from public.shop_event_participants participant
            where participant.event_id in (
                select (event_row.event->>'id')::uuid
                from public.fetch_active_shop_events(s.id) as event_row(event)
            )
        ), '[]'::jsonb),
        (select to_jsonb(notice) from public.shop_operating_notices notice
         where notice.shop_id = s.id
           and (notice.end_date is null or notice.end_date >= (current_timestamp at time zone 'Asia/Seoul')::date)
         order by notice.notice_date desc, notice.id limit 1)
    from public.ramen_shops s
    where s.id = p_shop_id;
$function$;

-- This existing endpoint remains the source of menu visibility, ordering and timestamp.
create or replace function public.fetch_shop_menu(p_shop_id uuid)
returns table(menu_sections jsonb, menu_items jsonb, menu_updated_at timestamp with time zone)
language sql stable security invoker
set search_path = ''
as $function$
    select
        coalesce((select jsonb_agg(to_jsonb(section) order by case when trim(section.title) = '상시메뉴' then 1 else 0 end, section.display_order, section.id)
                  from public.shop_menu_sections section where section.shop_id = s.id and section.is_visible), '[]'::jsonb),
        coalesce((select jsonb_agg(to_jsonb(item) order by item.display_order, item.id)
                  from public.visible_shop_menu_items item where item.shop_id = s.id), '[]'::jsonb),
        public.fetch_shop_menu_updated_at(s.id)
    from public.ramen_shops s
    where s.id = p_shop_id;
$function$;

revoke all on function public.fetch_shop_detail_v3(uuid) from public, anon, authenticated, service_role;
grant execute on function public.fetch_shop_detail_v3(uuid) to anon, authenticated, service_role;
revoke all on function public.fetch_shop_menu(uuid) from public, anon, authenticated, service_role;
grant execute on function public.fetch_shop_menu(uuid) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
