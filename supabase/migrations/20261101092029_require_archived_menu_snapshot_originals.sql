-- Apply only after every legacy original has been round-trip verified and moved.
DO $check$
BEGIN
    IF EXISTS (SELECT 1 FROM public.shop_menu_snapshots WHERE raw_dom IS NOT NULL) THEN
        RAISE EXCEPTION 'inline menu snapshot originals remain; finish verified archival first';
    END IF;
END;
$check$;
ALTER TABLE public.shop_menu_snapshots ADD CONSTRAINT shop_menu_snapshots_original_must_be_archived
    CHECK (raw_dom IS NULL);

-- Supabase's default privileges may otherwise leave UPDATE granted to service_role.
REVOKE ALL ON public.menu_snapshot_raw_objects FROM service_role;
GRANT SELECT,INSERT,DELETE ON public.menu_snapshot_raw_objects TO service_role;
