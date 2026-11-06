BEGIN;

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
        coalesce((
            SELECT jsonb_agg(event_row.event ORDER BY event_row.event->>'start_date', event_row.event->>'id')
            FROM public.fetch_active_shop_events(s.id) AS event_row(event)
            WHERE event_row.event->'venue_shop' <> 'null'::jsonb
        ), '[]'::jsonb),
        coalesce((
            SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id)
            FROM public.shop_event_participants AS participant
            WHERE participant.event_id IN (
                SELECT (event_row.event->>'id')::uuid
                FROM public.fetch_active_shop_events(s.id) AS event_row(event)
                WHERE event_row.event->'venue_shop' <> 'null'::jsonb
            )
        ), '[]'::jsonb),
        (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1),
        coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb),
        coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb)
    FROM public.ramen_shops AS s
    WHERE s.id = p_shop_id;
$function$;

DO $migration$
DECLARE
    v_menu_updated_at_type text;
BEGIN
    SELECT format_type(attribute.atttypid, attribute.atttypmod)
    INTO v_menu_updated_at_type
    FROM pg_catalog.pg_proc AS procedure
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
    JOIN pg_catalog.pg_type AS return_type ON return_type.oid = procedure.prorettype
    JOIN pg_catalog.pg_class AS return_relation ON return_relation.oid = return_type.typrelid
    JOIN pg_catalog.pg_attribute AS attribute ON attribute.attrelid = return_relation.oid
    WHERE namespace.nspname = 'public'
        AND procedure.proname = 'fetch_shop_detail_v2'
        AND procedure.proargtypes = '2950'::oidvector
        AND attribute.attname = 'menu_updated_at'
        AND NOT attribute.attisdropped;

    IF v_menu_updated_at_type IS NULL THEN
        EXECUTE $function$
            CREATE OR REPLACE FUNCTION public.fetch_shop_detail_v2(p_shop_id uuid)
            RETURNS TABLE(shop jsonb, like_count bigint, waiting_system jsonb, events jsonb, event_participants jsonb, operating_notice jsonb, menu_sections jsonb, menu_items jsonb)
            LANGUAGE sql
            STABLE
            SET search_path TO ''
            AS $body$
                SELECT
                    to_jsonb(s) || jsonb_build_object(
                        'phone', NULL::text,
                        'kakao_place_id', substring(s.kakao_place_url FROM '^https?://place\.map\.kakao\.com/([0-9]+)([/?#]|$)')
                    ),
                    coalesce((SELECT counts.like_count FROM public.shop_bookmark_counts AS counts WHERE counts.shop_id = s.id LIMIT 1), 0)::bigint,
                    (SELECT to_jsonb(waiting) FROM public.shop_waiting_systems AS waiting WHERE waiting.shop_id = s.id LIMIT 1),
                    coalesce((SELECT jsonb_agg(event_row.event ORDER BY event_row.event->>'start_date', event_row.event->>'id') FROM public.fetch_active_shop_events(s.id) AS event_row(event)), '[]'::jsonb),
                    coalesce((SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id) FROM public.shop_event_participants AS participant WHERE participant.event_id IN (SELECT (event_row.event->>'id')::uuid FROM public.fetch_active_shop_events(s.id) AS event_row(event))), '[]'::jsonb),
                    (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1),
                    coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb),
                    coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb)
                FROM public.ramen_shops AS s
                WHERE s.id = p_shop_id;
            $body$
        $function$;
    ELSE
        EXECUTE format($function$
            CREATE OR REPLACE FUNCTION public.fetch_shop_detail_v2(p_shop_id uuid)
            RETURNS TABLE(shop jsonb, like_count bigint, waiting_system jsonb, events jsonb, event_participants jsonb, operating_notice jsonb, menu_sections jsonb, menu_items jsonb, menu_updated_at %s)
            LANGUAGE sql
            STABLE
            SET search_path TO ''
            AS $body$
                SELECT
                    to_jsonb(s) || jsonb_build_object(
                        'phone', NULL::text,
                        'kakao_place_id', substring(s.kakao_place_url FROM '^https?://place\.map\.kakao\.com/([0-9]+)([/?#]|$)')
                    ),
                    coalesce((SELECT counts.like_count FROM public.shop_bookmark_counts AS counts WHERE counts.shop_id = s.id LIMIT 1), 0)::bigint,
                    (SELECT to_jsonb(waiting) FROM public.shop_waiting_systems AS waiting WHERE waiting.shop_id = s.id LIMIT 1),
                    coalesce((SELECT jsonb_agg(event_row.event ORDER BY event_row.event->>'start_date', event_row.event->>'id') FROM public.fetch_active_shop_events(s.id) AS event_row(event)), '[]'::jsonb),
                    coalesce((SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id) FROM public.shop_event_participants AS participant WHERE participant.event_id IN (SELECT (event_row.event->>'id')::uuid FROM public.fetch_active_shop_events(s.id) AS event_row(event))), '[]'::jsonb),
                    (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1),
                    coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb),
                    coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb),
                    public.fetch_shop_menu_updated_at(s.id)
                FROM public.ramen_shops AS s
                WHERE s.id = p_shop_id;
            $body$
        $function$, v_menu_updated_at_type);
    END IF;
END;
$migration$;

DROP POLICY "Anyone can read visible shop menu items" ON public.shop_menu_items;

CREATE POLICY "Anyone can read visible shop menu items"
ON public.shop_menu_items
AS PERMISSIVE
FOR SELECT
TO anon, authenticated
USING (
    is_visible
    AND EXISTS (
        SELECT 1
        FROM public.shop_menu_sections AS sections
        WHERE sections.id = shop_menu_items.section_id
            AND sections.is_visible
    )
    AND (
        event_id IS NULL
        OR EXISTS (
            SELECT 1
            FROM public.shop_events AS events
            JOIN public.ramen_shops AS venue ON venue.id = events.shop_id
            WHERE events.id = shop_menu_items.event_id
                AND events.event_type = ANY(ARRAY['collab', 'popup', 'limited_menu', 'summer_limited', 'new_menu', 'store_renewal'])
                AND public.event_is_active_on(events.event_type, events.start_date, events.end_date, (current_timestamp AT TIME ZONE 'Asia/Seoul')::date)
        )
    )
);

NOTIFY pgrst, 'reload schema';
COMMIT;
