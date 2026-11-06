CREATE OR REPLACE FUNCTION public.archive_shop_menu_snapshot(p_snapshot_id uuid,p_raw_sha256 text)
RETURNS text LANGUAGE plpgsql SET search_path='' AS $function$
DECLARE
    existing_hash text;
    has_inline_original boolean;
BEGIN
    SELECT raw_object_sha256,raw_dom IS NOT NULL INTO STRICT existing_hash,has_inline_original
    FROM public.shop_menu_snapshots WHERE id=p_snapshot_id FOR UPDATE;
    IF NOT has_inline_original THEN
        IF existing_hash IS DISTINCT FROM p_raw_sha256 THEN
            RAISE EXCEPTION 'snapshot is already bound to a different original';
        END IF;
        RETURN 'already_archived';
    END IF;
    -- resolve_menu_snapshot_raw_object hashes OLD.raw_dom inside this UPDATE.
    -- Hashing the same TOAST value here as well would read and decompress every original twice.
    UPDATE public.shop_menu_snapshots SET raw_dom=NULL,raw_object_sha256=p_raw_sha256 WHERE id=p_snapshot_id;
    RETURN 'archived';
END;
$function$;
REVOKE ALL ON FUNCTION public.archive_shop_menu_snapshot(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_shop_menu_snapshot(uuid,text) TO service_role;
