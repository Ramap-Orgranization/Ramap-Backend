BEGIN;

CREATE OR REPLACE FUNCTION public.fetch_active_events(p_event_id uuid DEFAULT NULL)
RETURNS SETOF jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $function$
    SELECT to_jsonb(active_event) - 'created_at'
    FROM (
        SELECT
            event.id,
            event.event_type,
            event.title,
            event.description,
            event.start_date,
            event.end_date,
            event.source_url,
            public.event_is_today_on(event.event_type, event.start_date, event.end_date, (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) AS is_today,
            event.shop_id IS NOT NULL AS is_venue,
            to_jsonb(venue.*) AS venue_shop,
            coalesce((
                SELECT jsonb_agg(to_jsonb(collaborator_shop.*) ORDER BY participant.created_at)
                FROM public.shop_event_participants AS participant
                JOIN public.ramen_shops AS collaborator_shop ON collaborator_shop.id = participant.shop_id
                WHERE participant.event_id = event.id
                    AND participant.shop_id IS DISTINCT FROM event.shop_id
            ), '[]'::jsonb) AS collaborator_shops,
            coalesce((
                SELECT jsonb_agg(jsonb_build_object('name', participant.external_name, 'instagram_url', participant.external_instagram_url) ORDER BY participant.created_at)
                FROM public.shop_event_participants AS participant
                WHERE participant.event_id = event.id
                    AND participant.shop_id IS NULL
            ), '[]'::jsonb) AS external_participants,
            event.waiting_method,
            event.waiting_url,
            event.cancelled_dates,
            (current_timestamp AT TIME ZONE 'Asia/Seoul')::date = ANY(event.cancelled_dates) AS is_cancelled_today,
            event.image_paths,
            event.sold_out_dates,
            (current_timestamp AT TIME ZONE 'Asia/Seoul')::date = ANY(event.sold_out_dates) AS is_sold_out_today,
            CASE
                WHEN (current_timestamp AT TIME ZONE 'Asia/Seoul')::date = ANY(event.cancelled_dates) THEN event.cancellation_reason
                ELSE NULL::text
            END AS cancellation_reason,
            event.cancellation_source_url,
            event.venue_name,
            event.venue_instagram_url,
            event.venue_naver_map_url,
            event.venue_kakao_map_url,
            to_jsonb(external_venue.*) AS external_venue,
            event.created_at
        FROM public.shop_events AS event
        LEFT JOIN public.ramen_shops AS venue ON venue.id = event.shop_id
        LEFT JOIN public.external_venues AS external_venue ON external_venue.id = event.external_venue_id
        WHERE event.event_type = ANY(ARRAY['collab', 'popup', 'limited_menu', 'summer_limited', 'new_menu', 'store_renewal'])
            AND public.event_is_active_on(event.event_type, event.start_date, event.end_date, (current_timestamp AT TIME ZONE 'Asia/Seoul')::date)
            AND (p_event_id IS NULL OR event.id = p_event_id)
    ) AS active_event
    ORDER BY active_event.created_at DESC, active_event.id DESC;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_active_shop_events(p_shop_id uuid)
RETURNS SETOF jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO ''
AS $function$
    WITH active_events AS (
        SELECT
            event.id,
            event.event_type,
            event.title,
            event.description,
            event.start_date,
            event.end_date,
            event.source_url,
            public.event_is_today_on(event.event_type, event.start_date, event.end_date, (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) AS is_today,
            event.shop_id IS NOT NULL AS is_venue,
            to_jsonb(venue.*) AS venue_shop,
            coalesce((
                SELECT jsonb_agg(to_jsonb(collaborator_shop.*) ORDER BY participant.created_at)
                FROM public.shop_event_participants AS participant
                JOIN public.ramen_shops AS collaborator_shop ON collaborator_shop.id = participant.shop_id
                WHERE participant.event_id = event.id
                    AND participant.shop_id IS DISTINCT FROM event.shop_id
            ), '[]'::jsonb) AS collaborator_shops,
            coalesce((
                SELECT jsonb_agg(jsonb_build_object('name', participant.external_name, 'instagram_url', participant.external_instagram_url) ORDER BY participant.created_at)
                FROM public.shop_event_participants AS participant
                WHERE participant.event_id = event.id
                    AND participant.shop_id IS NULL
            ), '[]'::jsonb) AS external_participants,
            event.waiting_method,
            event.waiting_url,
            event.cancelled_dates,
            (current_timestamp AT TIME ZONE 'Asia/Seoul')::date = ANY(event.cancelled_dates) AS is_cancelled_today,
            event.image_paths,
            event.sold_out_dates,
            (current_timestamp AT TIME ZONE 'Asia/Seoul')::date = ANY(event.sold_out_dates) AS is_sold_out_today,
            CASE
                WHEN (current_timestamp AT TIME ZONE 'Asia/Seoul')::date = ANY(event.cancelled_dates) THEN event.cancellation_reason
                ELSE NULL::text
            END AS cancellation_reason,
            event.cancellation_source_url,
            event.venue_name,
            event.venue_instagram_url,
            event.venue_naver_map_url,
            event.venue_kakao_map_url,
            to_jsonb(external_venue.*) AS external_venue,
            event.created_at
        FROM public.shop_events AS event
        LEFT JOIN public.ramen_shops AS venue ON venue.id = event.shop_id
        LEFT JOIN public.external_venues AS external_venue ON external_venue.id = event.external_venue_id
        WHERE event.event_type = ANY(ARRAY['collab', 'popup', 'limited_menu', 'summer_limited', 'new_menu', 'store_renewal'])
            AND public.event_is_active_on(event.event_type, event.start_date, event.end_date, (current_timestamp AT TIME ZONE 'Asia/Seoul')::date)
    )
    SELECT (to_jsonb(active_event) - 'created_at') || jsonb_build_object(
        'shop_context_id', event_context.shop_context_id,
        'is_venue', coalesce(event_context.shop_context_id = event.shop_id, false)
    )
    FROM active_events AS active_event
    JOIN public.shop_events AS event ON event.id = active_event.id
    CROSS JOIN LATERAL (
        SELECT event.shop_id AS shop_context_id
        UNION
        SELECT participant.shop_id
        FROM public.shop_event_participants AS participant
        WHERE participant.event_id = event.id
            AND participant.shop_id IS NOT NULL
    ) AS event_context
    WHERE event_context.shop_context_id = p_shop_id
    ORDER BY active_event.start_date;
$function$;

REVOKE ALL ON FUNCTION public.fetch_active_events(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fetch_active_shop_events(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fetch_active_events(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_active_shop_events(uuid) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
