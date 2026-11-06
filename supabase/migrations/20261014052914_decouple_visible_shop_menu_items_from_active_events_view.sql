BEGIN;

CREATE OR REPLACE VIEW public.visible_shop_menu_items
WITH (security_invoker = true)
AS
SELECT
    items.id,
    sections.shop_id,
    items.section_id,
    items.name,
    items.price_krw,
    items.price_text,
    items.description,
    items.image_url,
    items.source_url,
    items.event_id,
    items.display_order,
    items.is_featured
FROM public.shop_menu_items AS items
JOIN public.shop_menu_sections AS sections ON sections.id = items.section_id
WHERE items.is_visible
    AND sections.is_visible
    AND (
        items.event_id IS NULL
        OR EXISTS (
            SELECT 1
            FROM public.shop_events AS events
            JOIN public.ramen_shops AS venue ON venue.id = events.shop_id
            WHERE events.id = items.event_id
                AND events.event_type = ANY(ARRAY['collab', 'popup', 'limited_menu', 'summer_limited', 'new_menu', 'store_renewal'])
                AND public.event_is_active_on(events.event_type, events.start_date, events.end_date, (current_timestamp AT TIME ZONE 'Asia/Seoul')::date)
        )
    );

NOTIFY pgrst, 'reload schema';
COMMIT;
