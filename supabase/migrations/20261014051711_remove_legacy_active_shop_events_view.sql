-- Keep the legacy RPC callable for older clients while moving its event query
-- to the v2 view. Preserve the old shop-venue-only result filter.
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
        ),
        coalesce((SELECT counts.like_count FROM public.shop_bookmark_counts AS counts WHERE counts.shop_id = s.id LIMIT 1), 0)::bigint,
        (SELECT to_jsonb(waiting) FROM public.shop_waiting_systems AS waiting WHERE waiting.shop_id = s.id LIMIT 1),
        coalesce((SELECT jsonb_agg(to_jsonb(shop_event) ORDER BY shop_event.start_date, shop_event.id) FROM public.active_shop_events_v2 AS shop_event WHERE shop_event.shop_context_id = s.id AND shop_event.venue_shop IS NOT NULL), '[]'::jsonb),
        coalesce((SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id) FROM public.shop_event_participants AS participant WHERE participant.event_id IN (SELECT shop_event.id FROM public.active_shop_events_v2 AS shop_event WHERE shop_event.shop_context_id = s.id AND shop_event.venue_shop IS NOT NULL)), '[]'::jsonb),
        (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1),
        coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb),
        coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb)
    FROM public.ramen_shops AS s
    WHERE s.id = p_shop_id;
$function$;

DROP VIEW public.active_shop_events RESTRICT;
