CREATE FUNCTION public.archive_shop_menu_snapshot_batch(p_bindings jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $function$
DECLARE
    binding jsonb;
    result jsonb := '[]'::jsonb;
BEGIN
    IF p_bindings IS NULL OR jsonb_typeof(p_bindings) <> 'array' THEN
        RAISE EXCEPTION 'archive bindings must be an array';
    END IF;
    IF jsonb_array_length(p_bindings) NOT BETWEEN 1 AND 100
       OR (SELECT count(DISTINCT value->>'snapshot_id') FROM jsonb_array_elements(p_bindings)) <> jsonb_array_length(p_bindings) THEN
        RAISE EXCEPTION 'archive batch must contain 1..100 distinct snapshots';
    END IF;
    FOR binding IN SELECT value FROM jsonb_array_elements(p_bindings) ORDER BY value->>'snapshot_id' LOOP
        IF binding->>'snapshot_id' IS NULL OR binding->>'raw_sha256' IS NULL THEN
            RAISE EXCEPTION 'archive binding must identify the snapshot and original';
        END IF;
        result := result || jsonb_build_array(jsonb_build_object(
            'snapshot_id',binding->>'snapshot_id',
            'status',public.archive_shop_menu_snapshot((binding->>'snapshot_id')::uuid,binding->>'raw_sha256')));
    END LOOP;
    RETURN result;
END;
$function$;
REVOKE ALL ON FUNCTION public.archive_shop_menu_snapshot_batch(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_shop_menu_snapshot_batch(jsonb) TO service_role;
