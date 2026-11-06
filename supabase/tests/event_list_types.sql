-- 격리된 로컬 또는 staging DB에서 실행한다. 픽스처는 모두 롤백한다.
BEGIN;
SET LOCAL statement_timeout = '30s';

CREATE TEMPORARY TABLE event_list_fixture_ids(label text PRIMARY KEY, id uuid DEFAULT gen_random_uuid());
INSERT INTO event_list_fixture_ids(label) VALUES
    ('shop'), ('hidden-shop'), ('collab-today'), ('popup-upcoming'),
    ('limited-today'), ('summer-upcoming'), ('new-today'), ('new-upcoming'),
    ('renewal-today'), ('renewal-upcoming'), ('expired'), ('hidden');
GRANT SELECT ON event_list_fixture_ids TO anon, authenticated;

INSERT INTO public.ramen_shops(id, name, address, lat, lng, is_visible)
SELECT id, '이벤트 목록 회귀 픽스처', '테스트 주소', 37.5, 127.0, label = 'shop'
FROM event_list_fixture_ids WHERE label IN ('shop', 'hidden-shop');

INSERT INTO public.shop_events(id, shop_id, title, description, start_date, end_date, event_type, source_url, created_at)
SELECT fixture.id,
       (SELECT id FROM event_list_fixture_ids WHERE label = CASE WHEN fixture.label = 'hidden' THEN 'hidden-shop' ELSE 'shop' END),
       fixture.label, '테스트 설명',
       (current_timestamp AT TIME ZONE 'Asia/Seoul')::date + CASE
           WHEN fixture.label LIKE '%upcoming' THEN 1
           WHEN fixture.label = 'expired' THEN -2
           ELSE 0 END,
       CASE
           WHEN fixture.label LIKE 'new-%' OR fixture.label LIKE 'renewal-%' THEN NULL::date
           ELSE (current_timestamp AT TIME ZONE 'Asia/Seoul')::date + CASE WHEN fixture.label = 'expired' THEN -1 ELSE 2 END END,
       CASE
           WHEN fixture.label = 'collab-today' THEN 'collab'
           WHEN fixture.label = 'popup-upcoming' THEN 'popup'
           WHEN fixture.label = 'summer-upcoming' THEN 'summer_limited'
           WHEN fixture.label LIKE 'new-%' THEN 'new_menu'
           WHEN fixture.label LIKE 'renewal-%' THEN 'store_renewal'
           ELSE 'limited_menu' END,
       'https://example.com/' || fixture.label,
       timestamptz '2026-01-01 00:00:00+00' + CASE fixture.label
           WHEN 'collab-today' THEN interval '1 hour'
           WHEN 'popup-upcoming' THEN interval '2 hours'
           WHEN 'limited-today' THEN interval '3 hours'
           WHEN 'summer-upcoming' THEN interval '4 hours'
           ELSE interval '5 hours' END
FROM event_list_fixture_ids AS fixture WHERE fixture.label NOT IN ('shop', 'hidden-shop');

DO $test$
DECLARE
    actor text;
    fixture record;
    listed_ids uuid[];
    detail jsonb;
    original_rows jsonb;
    expected_ids uuid[] := ARRAY[
        (SELECT id FROM event_list_fixture_ids WHERE label = 'summer-upcoming'),
        (SELECT id FROM event_list_fixture_ids WHERE label = 'limited-today'),
        (SELECT id FROM event_list_fixture_ids WHERE label = 'popup-upcoming'),
        (SELECT id FROM event_list_fixture_ids WHERE label = 'collab-today')
    ];
BEGIN
    SELECT jsonb_agg(to_jsonb(event) ORDER BY event.id) INTO original_rows
    FROM public.shop_events AS event JOIN event_list_fixture_ids AS fixture_id ON fixture_id.id = event.id;

    ASSERT NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.fetch_active_events(uuid)'::regprocedure),
        '이벤트 조회는 호출자 권한을 유지한다';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pg_proc AS routine, LATERAL aclexplode(routine.proacl) AS grant_entry
        WHERE routine.oid = 'public.fetch_active_events(uuid)'::regprocedure
            AND grant_entry.grantee = 0 AND grant_entry.privilege_type = 'EXECUTE'
    ), 'PUBLIC 역할에 실행 권한을 추가하지 않는다';

    FOR actor IN SELECT unnest(ARRAY['anon', 'authenticated']) LOOP
        PERFORM set_config('role', actor, true);
        SELECT array_agg((event->>'id')::uuid ORDER BY position) INTO listed_ids
        FROM public.fetch_active_events() WITH ORDINALITY AS result(event, position)
        WHERE (event->>'id')::uuid IN (SELECT id FROM event_list_fixture_ids);
        ASSERT listed_ids = expected_ids, '진행 중과 예정의 나머지 네 유형만 최신 등록순으로 반환한다';
        ASSERT NOT EXISTS (
            SELECT 1 FROM public.fetch_active_events(NULL) AS event
            WHERE event->>'event_type' IN ('new_menu', 'store_renewal')
        ), '목록 응답에서 신메뉴와 리뉴얼을 제외한다';

        FOR fixture IN
            SELECT * FROM event_list_fixture_ids WHERE label LIKE 'new-%' OR label LIKE 'renewal-%'
        LOOP
            SELECT event INTO STRICT detail FROM public.fetch_active_events(fixture.id) AS event;
            ASSERT detail->>'id' = fixture.id::text, '신메뉴와 리뉴얼의 개별 조회를 유지한다';
            ASSERT (detail->>'is_today')::boolean = (fixture.label LIKE '%today'), '진행 중과 예정 판정을 유지한다';
        END LOOP;

        ASSERT NOT EXISTS (
            SELECT 1 FROM public.fetch_active_events((SELECT id FROM event_list_fixture_ids WHERE label = 'expired'))
        ), '종료된 이벤트는 개별 활성 조회에서도 제외한다';
        ASSERT NOT EXISTS (
            SELECT 1 FROM public.fetch_active_events((SELECT id FROM event_list_fixture_ids WHERE label = 'hidden'))
        ), '숨김 매장 이벤트는 개별 조회에서도 공개하지 않는다';
        PERFORM set_config('role', 'none', true);
    END LOOP;

    ASSERT original_rows = (
        SELECT jsonb_agg(to_jsonb(event) ORDER BY event.id)
        FROM public.shop_events AS event JOIN event_list_fixture_ids AS fixture_id ON fixture_id.id = event.id
    ), '목록과 개별 조회는 기존 이벤트 데이터를 변경하지 않는다';
END;
$test$;
ROLLBACK;
