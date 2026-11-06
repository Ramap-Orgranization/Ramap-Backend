set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- Restrictive SELECT policies cannot be bypassed by another permissive read policy.
-- Trusted server writes keep their existing grants and bypass-RLS role.
create policy "Public readers only see visible shops"
on public.ramen_shops as restrictive for select to anon, authenticated
using (is_visible);

create policy "Public menu sections require visible shops"
on public.shop_menu_sections as restrictive for select to anon, authenticated
using (exists (
    select 1 from public.ramen_shops shop
    where shop.id = shop_menu_sections.shop_id and shop.is_visible
));

create policy "Public menu items require visible shops"
on public.shop_menu_items as restrictive for select to anon, authenticated
using (exists (
    select 1
    from public.shop_menu_sections section
    join public.ramen_shops shop on shop.id = section.shop_id
    where section.id = shop_menu_items.section_id and shop.is_visible
));

create policy "Public events require visible venues"
on public.shop_events as restrictive for select to anon, authenticated
using (shop_id is null or exists (
    select 1 from public.ramen_shops shop
    where shop.id = shop_events.shop_id and shop.is_visible
));

create policy "Public participants require visible events and shops"
on public.shop_event_participants as restrictive for select to anon, authenticated
using (
    exists (select 1 from public.shop_events event where event.id = shop_event_participants.event_id)
    and (shop_id is null or exists (
        select 1 from public.ramen_shops shop
        where shop.id = shop_event_participants.shop_id and shop.is_visible
    ))
);

create policy "Public operating notices require visible shops"
on operating_notice_private.shop_operating_notices
as restrictive for select to anon, authenticated
using (exists (
    select 1 from public.ramen_shops shop
    where shop.id = shop_operating_notices.shop_id and shop.is_visible
));

create policy "Public operating status requires visible shops"
on public.shop_operating_status as restrictive for select to anon, authenticated
using (exists (
    select 1 from public.ramen_shops shop
    where shop.id = shop_operating_status.shop_id and shop.is_visible
));

create policy "Public bookmark counts require visible shops"
on public.shop_bookmark_counts as restrictive for select to anon, authenticated
using (exists (
    select 1 from public.ramen_shops shop
    where shop.id = shop_bookmark_counts.shop_id and shop.is_visible
));

create policy "Public menu exclusion rules require visible shops"
on public.shop_menu_exclusion_rules as restrictive for select to anon, authenticated
using (exists (
    select 1 from public.ramen_shops shop
    where shop.id = shop_menu_exclusion_rules.shop_id and shop.is_visible
));

-- The existing diagnostic view otherwise evaluates its tables as the owner.
alter view public.shop_menu_duplicate_candidates set (security_invoker = true);

-- These existing SECURITY DEFINER read APIs need explicit public-scope checks.
create or replace function public.fetch_shop_menu_updated_at(p_shop_id uuid)
returns timestamp with time zone
language sql stable security definer
set search_path = ''
as $function$
    select menu_timestamp.updated_at
    from public.shop_menu_update_timestamps menu_timestamp
    join public.ramen_shops shop on shop.id = menu_timestamp.shop_id
    where menu_timestamp.shop_id = p_shop_id and shop.is_visible;
$function$;

create or replace function public.fetch_menu_recommendation_counts(p_menu_ids uuid[])
returns table(menu_id uuid, recommendation_count bigint)
language sql security definer
set search_path = ''
as $function$
    select recommendation.menu_id, count(*)::bigint
    from public.user_shop_menu_recommendations recommendation
    join public.visible_shop_menu_items menu on menu.id = recommendation.menu_id
    join public.ramen_shops shop on shop.id = menu.shop_id
    left join public.shop_events event on event.id = menu.event_id
    left join public.ramen_shops venue on venue.id = event.shop_id
    where recommendation.menu_id = any(p_menu_ids)
      and shop.is_visible
      and (menu.event_id is null or venue.is_visible)
    group by recommendation.menu_id;
$function$;

notify pgrst, 'reload schema';
