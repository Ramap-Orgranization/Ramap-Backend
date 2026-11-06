create schema operating_notice_private;
revoke all on schema operating_notice_private from public, anon, authenticated;
grant usage on schema operating_notice_private to service_role;
alter table public.shop_operating_notices set schema operating_notice_private;
revoke all on operating_notice_private.shop_operating_notices from public, anon, authenticated;
grant select (id, shop_id, notice_type, description, notice_date, start_time, end_time, source_url, created_at, updated_at, end_date, schedule_override, manually_released_at, daily_schedules) on operating_notice_private.shop_operating_notices to anon, authenticated;
create view public.shop_operating_notices with (security_invoker = true) as
select id, shop_id, notice_type, description, notice_date, start_time, end_time, source_url, created_at, updated_at, end_date, schedule_override, manually_released_at, daily_schedules from operating_notice_private.shop_operating_notices;
revoke all on public.shop_operating_notices from public, anon, authenticated, service_role;
grant select on public.shop_operating_notices to anon, authenticated, service_role;
create or replace view public.admin_shop_operating_notice_records with (security_invoker = true) as
select id, shop_id, raw_post_id, notice_type, description, notice_date, start_time, end_time, source_url, ocr_text, confidence, review_note, created_at, updated_at, end_date, schedule_override, manually_released_at, daily_schedules from operating_notice_private.shop_operating_notices;
revoke all on public.admin_shop_operating_notice_records from public, anon, authenticated;
grant select, insert, update, delete on public.admin_shop_operating_notice_records to service_role;
comment on schema operating_notice_private is 'Unexposed original operating notice storage; public view exposes only app fields.';
comment on view public.shop_operating_notices is 'Public read-only operating notice projection. OCR, review note, confidence and raw post ID stay private.';
comment on view public.admin_shop_operating_notice_records is 'Service-only operating notice maintenance, including OCR and review metadata.';
CREATE OR REPLACE FUNCTION public.fetch_shop_detail(p_shop_id uuid)
 RETURNS TABLE(shop jsonb, like_count bigint, waiting_system jsonb, events jsonb, event_participants jsonb, operating_notice jsonb, menu_sections jsonb, menu_items jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
    SELECT
        to_jsonb(s) || jsonb_build_object(
            'phone', NULL::text,
            'kakao_place_id', substring(s.kakao_place_url FROM '^https?://place\.map\.kakao\.com/([0-9]+)([/?#]|$)')
        ) AS shop,
        coalesce((SELECT counts.like_count FROM public.shop_bookmark_counts AS counts WHERE counts.shop_id = s.id LIMIT 1), 0)::bigint AS like_count,
        (SELECT to_jsonb(waiting) FROM public.shop_waiting_systems AS waiting WHERE waiting.shop_id = s.id LIMIT 1) AS waiting_system,
        coalesce((SELECT jsonb_agg(to_jsonb(shop_event) ORDER BY shop_event.start_date, shop_event.id) FROM public.active_shop_events AS shop_event WHERE shop_event.shop_context_id = s.id), '[]'::jsonb) AS events,
        coalesce((SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id) FROM public.shop_event_participants AS participant WHERE participant.event_id IN (SELECT shop_event.id FROM public.active_shop_events AS shop_event WHERE shop_event.shop_context_id = s.id)), '[]'::jsonb) AS event_participants,
        (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1) AS operating_notice,
        coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb) AS menu_sections,
        coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb) AS menu_items
    FROM public.ramen_shops AS s
    WHERE s.id = p_shop_id;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_detail_v2(p_shop_id uuid)
 RETURNS TABLE(shop jsonb, like_count bigint, waiting_system jsonb, events jsonb, event_participants jsonb, operating_notice jsonb, menu_sections jsonb, menu_items jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
    SELECT
        to_jsonb(s) || jsonb_build_object(
            'phone', NULL::text,
            'kakao_place_id', substring(s.kakao_place_url FROM '^https?://place\.map\.kakao\.com/([0-9]+)([/?#]|$)')
        ),
        coalesce((SELECT counts.like_count FROM public.shop_bookmark_counts AS counts WHERE counts.shop_id = s.id LIMIT 1), 0)::bigint,
        (SELECT to_jsonb(waiting) FROM public.shop_waiting_systems AS waiting WHERE waiting.shop_id = s.id LIMIT 1),
        coalesce((SELECT jsonb_agg(to_jsonb(shop_event) ORDER BY shop_event.start_date, shop_event.id) FROM public.active_shop_events_v2 AS shop_event WHERE shop_event.shop_context_id = s.id), '[]'::jsonb),
        coalesce((SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id) FROM public.shop_event_participants AS participant WHERE participant.event_id IN (SELECT shop_event.id FROM public.active_shop_events_v2 AS shop_event WHERE shop_event.shop_context_id = s.id)), '[]'::jsonb),
        (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1),
        coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb),
        coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb)
    FROM public.ramen_shops AS s
    WHERE s.id = p_shop_id;
$function$;

CREATE OR REPLACE FUNCTION public.release_shop_operating_notice(notice_id uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    update shop_operating_notices
    set manually_released_at = coalesce(manually_released_at, now())
    where id = notice_id and notice_type = 'late_opening'
    returning manually_released_at;
$function$;

notify pgrst, 'reload schema';
