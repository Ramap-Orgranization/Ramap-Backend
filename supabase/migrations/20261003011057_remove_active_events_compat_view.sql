-- Preserve the shop-only compatibility filter used by menu visibility,
-- move the matching RLS predicate off the legacy view, then remove it without
-- cascading dependencies.
BEGIN;

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
            FROM public.active_events_v2 AS events
            WHERE events.id = shop_menu_items.event_id
              AND events.venue_shop IS NOT NULL
        )
    )
);

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
          FROM public.active_events_v2 AS events
          WHERE events.id = items.event_id
            AND events.venue_shop IS NOT NULL
      )
  );

DROP VIEW public.active_events RESTRICT;

COMMIT;
