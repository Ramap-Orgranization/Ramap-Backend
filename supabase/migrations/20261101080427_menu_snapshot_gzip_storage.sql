-- Originals remain readable inline until their private gzip object has been round-trip verified.
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('menu-snapshot-raw', 'menu-snapshot-raw', false, 16777216, ARRAY['application/gzip'])
ON CONFLICT (id) DO UPDATE SET public=false, file_size_limit=16777216,
    allowed_mime_types=ARRAY['application/gzip'];

CREATE POLICY menu_snapshot_raw_server_only ON storage.objects AS RESTRICTIVE
    FOR ALL TO anon, authenticated
    USING (bucket_id <> 'menu-snapshot-raw')
    WITH CHECK (bucket_id <> 'menu-snapshot-raw');

CREATE TABLE public.menu_snapshot_raw_objects (
    raw_sha256 text PRIMARY KEY CHECK (raw_sha256 ~ '^[0-9a-f]{64}$'),
    storage_bucket text NOT NULL DEFAULT 'menu-snapshot-raw' CHECK (storage_bucket='menu-snapshot-raw'),
    storage_path text NOT NULL UNIQUE,
    compression text NOT NULL DEFAULT 'gzip' CHECK (compression='gzip'),
    original_bytes bigint NOT NULL CHECK (original_bytes BETWEEN 1 AND 33554432),
    gzip_bytes bigint NOT NULL CHECK (gzip_bytes BETWEEN 1 AND 16777216),
    gzip_sha256 text NOT NULL CHECK (gzip_sha256 ~ '^[0-9a-f]{64}$'),
    verified_at timestamptz NOT NULL DEFAULT now(),
    CHECK (storage_path='sha256/' || left(raw_sha256,2) || '/' || raw_sha256 || '.html.gz')
);
ALTER TABLE public.menu_snapshot_raw_objects ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.menu_snapshot_raw_objects FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.menu_snapshot_raw_objects TO service_role;

CREATE FUNCTION public.check_menu_snapshot_raw_object() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM storage.objects o JOIN storage.buckets b ON b.id=o.bucket_id
        WHERE o.bucket_id=NEW.storage_bucket AND o.name=NEW.storage_path AND NOT b.public
          AND (o.metadata->>'size')::bigint=NEW.gzip_bytes
          AND o.metadata->>'mimetype'='application/gzip'
    ) THEN
        RAISE EXCEPTION 'verified private gzip object is missing or its metadata differs';
    END IF;
    RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.check_menu_snapshot_raw_object() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_menu_snapshot_raw_object() TO service_role;
CREATE TRIGGER check_menu_snapshot_raw_object BEFORE INSERT ON public.menu_snapshot_raw_objects
    FOR EACH ROW EXECUTE FUNCTION public.check_menu_snapshot_raw_object();

ALTER TABLE public.shop_menu_snapshots
    ALTER COLUMN raw_dom DROP NOT NULL,
    ADD COLUMN raw_object_sha256 text REFERENCES public.menu_snapshot_raw_objects(raw_sha256),
    ADD CONSTRAINT shop_menu_snapshots_original_location CHECK (num_nonnulls(raw_dom,raw_object_sha256)=1);
CREATE INDEX shop_menu_snapshots_raw_object_idx ON public.shop_menu_snapshots(raw_object_sha256);

CREATE FUNCTION public.resolve_menu_snapshot_raw_object() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $function$
DECLARE
    original_hash text;
BEGIN
    -- Existing SQL/RPC writers may still supply HTML after first archiving it through the helper.
    IF NEW.raw_dom IS NOT NULL THEN
        original_hash := encode(sha256(convert_to(NEW.raw_dom,'UTF8')),'hex');
        IF EXISTS (SELECT 1 FROM public.menu_snapshot_raw_objects WHERE raw_sha256=original_hash) THEN
            NEW.raw_object_sha256 := original_hash;
            NEW.raw_dom := NULL;
        END IF;
    END IF;
    IF TG_OP='UPDATE' AND OLD.raw_dom IS NOT NULL AND NEW.raw_dom IS NULL THEN
        IF NEW.raw_object_sha256 IS DISTINCT FROM encode(sha256(convert_to(OLD.raw_dom,'UTF8')),'hex') THEN
            RAISE EXCEPTION 'archived original differs from the existing snapshot original';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.resolve_menu_snapshot_raw_object() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_menu_snapshot_raw_object() TO service_role;
CREATE TRIGGER resolve_menu_snapshot_raw_object BEFORE INSERT OR UPDATE OF raw_dom,raw_object_sha256
    ON public.shop_menu_snapshots FOR EACH ROW EXECUTE FUNCTION public.resolve_menu_snapshot_raw_object();

CREATE FUNCTION public.archive_shop_menu_snapshot(p_snapshot_id uuid,p_raw_sha256 text)
RETURNS text LANGUAGE plpgsql SET search_path='' AS $function$
DECLARE
    snapshot public.shop_menu_snapshots%rowtype;
BEGIN
    SELECT * INTO STRICT snapshot FROM public.shop_menu_snapshots WHERE id=p_snapshot_id FOR UPDATE;
    IF snapshot.raw_dom IS NULL THEN
        IF snapshot.raw_object_sha256 IS DISTINCT FROM p_raw_sha256 THEN
            RAISE EXCEPTION 'snapshot is already bound to a different original';
        END IF;
        RETURN 'already_archived';
    END IF;
    IF p_raw_sha256 IS DISTINCT FROM encode(sha256(convert_to(snapshot.raw_dom,'UTF8')),'hex') THEN
        RAISE EXCEPTION 'snapshot original changed before archival';
    END IF;
    -- The FK and trigger verify registry membership and the original being removed atomically.
    UPDATE public.shop_menu_snapshots SET raw_dom=NULL,raw_object_sha256=p_raw_sha256 WHERE id=p_snapshot_id;
    RETURN 'archived';
END;
$function$;
REVOKE ALL ON FUNCTION public.archive_shop_menu_snapshot(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_shop_menu_snapshot(uuid,text) TO service_role;

COMMENT ON TABLE public.menu_snapshot_raw_objects IS
    'Server-only registry of immutable private gzip originals verified by download, decompression, size and SHA-256.';
COMMENT ON COLUMN public.shop_menu_snapshots.raw_object_sha256 IS
    'Actual UTF-8 original SHA-256. Legacy source_hash remains unchanged even when it has different historical semantics.';
