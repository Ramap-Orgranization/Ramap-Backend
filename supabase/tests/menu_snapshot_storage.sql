-- Run after one real original has been uploaded and verified. All synthetic DB rows roll back.
BEGIN;
DO $test$
DECLARE
    original public.menu_snapshot_raw_objects%rowtype;
    shop uuid := gen_random_uuid();
    snapshot uuid := gen_random_uuid();
    inline_snapshot uuid := gen_random_uuid();
    failed boolean;
    visible_objects bigint;
    status text;
BEGIN
    SELECT * INTO STRICT original FROM public.menu_snapshot_raw_objects ORDER BY raw_sha256 LIMIT 1;
    ASSERT NOT (SELECT public FROM storage.buckets WHERE id='menu-snapshot-raw'), '원문 버킷은 비공개다';
    ASSERT NOT has_table_privilege('anon','public.menu_snapshot_raw_objects','SELECT'), '비회원은 검증 기록을 읽지 못한다';
    ASSERT NOT has_table_privilege('authenticated','public.menu_snapshot_raw_objects','SELECT'), '회원은 검증 기록을 읽지 못한다';
    ASSERT NOT has_function_privilege('anon','public.archive_shop_menu_snapshot(uuid,text)','EXECUTE'), '비회원은 이전 RPC를 실행하지 못한다';
    ASSERT NOT has_function_privilege('authenticated','public.archive_shop_menu_snapshot_batch(jsonb)','EXECUTE'), '회원은 묶음 이전을 실행하지 못한다';

    SET LOCAL ROLE anon;
    SELECT count(*) INTO visible_objects FROM storage.objects WHERE bucket_id='menu-snapshot-raw';
    ASSERT visible_objects=0, '비회원에게 원문 파일이 보이지 않는다';
    RESET ROLE;
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO visible_objects FROM storage.objects WHERE bucket_id='menu-snapshot-raw';
    ASSERT visible_objects=0, '일반 회원에게 원문 파일이 보이지 않는다';
    RESET ROLE;

    INSERT INTO public.ramen_shops(id,name,address,lat,lng,menu_snapshot_enabled,is_visible)
    VALUES(shop,'gzip synthetic test','synthetic only',37,127,false,false);
    INSERT INTO public.shop_menu_snapshots(id,shop_id,source_url,parser_version,source_hash,raw_object_sha256,menu_items,menu_fingerprint)
    VALUES(snapshot,shop,'https://example.invalid/menu','gzip-test',repeat('0',64),original.raw_sha256,'[]',repeat('1',64));
    ASSERT (SELECT raw_dom IS NULL AND source_hash=repeat('0',64) AND raw_object_sha256=original.raw_sha256
        FROM public.shop_menu_snapshots WHERE id=snapshot), '과거 출처 해시를 보존하고 실제 원문 참조를 저장한다';
    status := public.archive_shop_menu_snapshot(snapshot,original.raw_sha256);
    ASSERT status='already_archived', '같은 원문의 재시도는 안전하다';

    failed := false;
    BEGIN
        PERFORM public.archive_shop_menu_snapshot(snapshot,repeat('f',64));
    EXCEPTION WHEN raise_exception THEN failed := true;
    END;
    ASSERT failed, '이미 이전한 스냅샷을 다른 원문으로 바꾸지 못한다';
    failed := false;
    BEGIN
        PERFORM public.archive_shop_menu_snapshot_batch(jsonb_build_array(
            jsonb_build_object('snapshot_id',snapshot,'raw_sha256',original.raw_sha256),
            jsonb_build_object('snapshot_id',snapshot,'raw_sha256',original.raw_sha256)));
    EXCEPTION WHEN raise_exception THEN failed := true;
    END;
    ASSERT failed, '묶음 이전은 중복 스냅샷을 거절한다';

    failed := false;
    BEGIN
        INSERT INTO public.shop_menu_snapshots(shop_id,source_url,parser_version,source_hash,raw_object_sha256,menu_items,menu_fingerprint)
        VALUES(shop,'https://example.invalid/menu','gzip-test',repeat('0',64),repeat('f',64),'[]',repeat('1',64));
    EXCEPTION WHEN foreign_key_violation THEN failed := true;
    END;
    ASSERT failed, '등록되지 않은 원문을 참조하지 못한다';

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.shop_menu_snapshots'::regclass
        AND conname='shop_menu_snapshots_original_must_be_archived') THEN
        INSERT INTO public.shop_menu_snapshots(id,shop_id,source_url,parser_version,source_hash,raw_dom,menu_items,menu_fingerprint)
        VALUES(inline_snapshot,shop,'https://example.invalid/menu','gzip-test',repeat('0',64),repeat('synthetic-original',10),'[]',repeat('1',64));
        failed := false;
        BEGIN
            UPDATE public.shop_menu_snapshots SET raw_dom=NULL,raw_object_sha256=original.raw_sha256 WHERE id=inline_snapshot;
        EXCEPTION WHEN raise_exception THEN failed := true;
        END;
        ASSERT failed AND (SELECT raw_dom IS NOT NULL FROM public.shop_menu_snapshots WHERE id=inline_snapshot),
            '복원 해시와 다른 파일로 원문을 제거하지 못한다';
    ELSE
        ASSERT NOT has_table_privilege('service_role','public.menu_snapshot_raw_objects','UPDATE'),
            '검증 기록은 서버의 일반 갱신 권한으로 재작성하지 못한다';
        failed := false;
        BEGIN
            INSERT INTO public.shop_menu_snapshots(shop_id,source_url,parser_version,source_hash,raw_dom,menu_items,menu_fingerprint)
            VALUES(shop,'https://example.invalid/menu','gzip-test',repeat('0',64),repeat('synthetic-original',10),'[]',repeat('1',64));
        EXCEPTION WHEN check_violation THEN failed := true;
        END;
        ASSERT failed, '이전 완료 후 인라인 원문을 새로 저장하지 못한다';
    END IF;
END;
$test$;
ROLLBACK;
SELECT true AS menu_snapshot_storage_tests_passed;
