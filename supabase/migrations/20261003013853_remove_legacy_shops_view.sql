BEGIN;

-- Move every live SQL consumer to the canonical ramen_shops table first.
CREATE OR REPLACE FUNCTION public.claim_due_shop_operating_statuses(batch_limit integer DEFAULT 10)
RETURNS TABLE(
    id text,
    name text,
    naver_place_url text,
    business_hours_weekly jsonb,
    business_hours_break_times jsonb,
    check_interval_minutes integer,
    check_reason text,
    consecutive_failures integer
)
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE safe_limit integer := least(greatest(coalesce(batch_limit, 10), 1), 50);
BEGIN
    INSERT INTO public.shop_operating_status (
        shop_id,
        source_url,
        next_check_at,
        check_interval_minutes,
        check_reason,
        consecutive_failures
    )
    SELECT shops.id, shops.naver_place_url, now(), 60, 'initial', 0
    FROM public.ramen_shops AS shops
    WHERE shops.is_visible AND shops.naver_place_url IS NOT NULL
    ON CONFLICT (shop_id) DO NOTHING;

    RETURN QUERY
    WITH due AS (
        SELECT status.shop_id
        FROM public.shop_operating_status AS status
        JOIN public.ramen_shops AS shops ON shops.id = status.shop_id
        WHERE shops.is_visible
          AND shops.naver_place_url IS NOT NULL
          AND status.next_check_at <= now()
        ORDER BY status.next_check_at, status.shop_id
        FOR UPDATE OF status SKIP LOCKED
        LIMIT safe_limit
    ), claimed AS (
        UPDATE public.shop_operating_status AS status
        SET next_check_at = now() + interval '60 minutes',
            check_reason = 'running'
        FROM due
        WHERE status.shop_id = due.shop_id
        RETURNING status.shop_id, status.consecutive_failures
    )
    SELECT shops.id::text,
           shops.name::text,
           shops.naver_place_url::text,
           shops.business_hours_weekly,
           shops.business_hours_break_times,
           status.check_interval_minutes,
           status.check_reason,
           claimed.consecutive_failures
    FROM claimed
    JOIN public.ramen_shops AS shops ON shops.id = claimed.shop_id
    JOIN public.shop_operating_status AS status ON status.shop_id = claimed.shop_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_ranking_sigungu(p_area text)
RETURNS TABLE(sigungu text)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
    WITH visible_shop_areas AS (
        SELECT
            split_part(btrim(shops.address), ' ', 2) AS sigungu,
            CASE split_part(btrim(shops.address), ' ', 1)
                WHEN '서울' THEN 'SEOUL'
                WHEN '서울특별시' THEN 'SEOUL'
                WHEN '부산' THEN 'BUSAN'
                WHEN '부산광역시' THEN 'BUSAN'
                WHEN '대구' THEN 'DAEGU'
                WHEN '대구광역시' THEN 'DAEGU'
                WHEN '인천' THEN 'INCHEON'
                WHEN '인천광역시' THEN 'INCHEON'
                WHEN '광주' THEN 'GWANGJU'
                WHEN '광주광역시' THEN 'GWANGJU'
                WHEN '대전' THEN 'DAEJEON'
                WHEN '대전광역시' THEN 'DAEJEON'
                WHEN '울산' THEN 'ULSAN'
                WHEN '울산광역시' THEN 'ULSAN'
                WHEN '세종' THEN 'SEJONG'
                WHEN '세종특별자치시' THEN 'SEJONG'
                WHEN '경기' THEN 'GYEONGGI'
                WHEN '경기도' THEN 'GYEONGGI'
                WHEN '충북' THEN 'CHUNGBUK'
                WHEN '충청북도' THEN 'CHUNGBUK'
                WHEN '충남' THEN 'CHUNGNAM'
                WHEN '충청남도' THEN 'CHUNGNAM'
                WHEN '전남' THEN 'JEONNAM'
                WHEN '전라남도' THEN 'JEONNAM'
                WHEN '전남광주통합특별시' THEN 'JEONNAM'
                WHEN '경북' THEN 'GYEONGBUK'
                WHEN '경상북도' THEN 'GYEONGBUK'
                WHEN '경남' THEN 'GYEONGNAM'
                WHEN '경상남도' THEN 'GYEONGNAM'
                WHEN '강원' THEN 'GANGWON'
                WHEN '강원도' THEN 'GANGWON'
                WHEN '강원특별자치도' THEN 'GANGWON'
                WHEN '전북' THEN 'JEONBUK'
                WHEN '전라북도' THEN 'JEONBUK'
                WHEN '전북특별자치도' THEN 'JEONBUK'
                WHEN '제주' THEN 'JEJU'
                WHEN '제주도' THEN 'JEJU'
                WHEN '제주특별자치도' THEN 'JEJU'
                ELSE NULL
            END AS area
        FROM public.ramen_shops AS shops
        WHERE shops.is_visible = true
    )
    SELECT DISTINCT visible_shop_areas.sigungu
    FROM visible_shop_areas
    WHERE visible_shop_areas.area = p_area
      AND visible_shop_areas.sigungu ~ '(시|군|구)$'
    ORDER BY visible_shop_areas.sigungu;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_detail(p_shop_id uuid)
RETURNS TABLE(
    shop jsonb,
    like_count bigint,
    waiting_system jsonb,
    events jsonb,
    event_participants jsonb,
    operating_notice jsonb,
    menu_sections jsonb,
    menu_items jsonb
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
    SELECT
        to_jsonb(s) || jsonb_build_object(
            'phone', NULL::text,
            'kakao_place_id', substring(s.kakao_place_url FROM '^https?://place\.map\.kakao\.com/([0-9]+)([/?#]|$)')
        ) AS shop,
        coalesce((SELECT counts.like_count FROM public.shop_bookmark_counts AS counts WHERE counts.shop_id = s.id LIMIT 1), 0)::bigint AS like_count,
        (SELECT to_jsonb(waiting) FROM public.shop_waiting_systems AS waiting WHERE waiting.shop_id = s.id LIMIT 1) AS waiting_system,
        coalesce((SELECT jsonb_agg(to_jsonb(shop_event) ORDER BY shop_event.start_date, shop_event.id) FROM public.active_shop_events AS shop_event WHERE shop_event.shop_context_id = s.id), '[]'::jsonb) AS events,
        coalesce((SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id) FROM public.shop_event_participants AS participant WHERE participant.event_id IN (SELECT shop_event.id FROM public.active_shop_events AS shop_event WHERE shop_event.shop_context_id = s.id)), '[]'::jsonb) AS event_participants,
        (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1) AS operating_notice,
        coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb) AS menu_sections,
        coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb) AS menu_items
    FROM public.ramen_shops AS s
    WHERE s.id = p_shop_id;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_detail_v2(p_shop_id uuid)
RETURNS TABLE(
    shop jsonb,
    like_count bigint,
    waiting_system jsonb,
    events jsonb,
    event_participants jsonb,
    operating_notice jsonb,
    menu_sections jsonb,
    menu_items jsonb
)
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
        coalesce((SELECT jsonb_agg(to_jsonb(shop_event) ORDER BY shop_event.start_date, shop_event.id) FROM public.active_shop_events_v2 AS shop_event WHERE shop_event.shop_context_id = s.id), '[]'::jsonb),
        coalesce((SELECT jsonb_agg(to_jsonb(participant) ORDER BY participant.event_id, participant.shop_id) FROM public.shop_event_participants AS participant WHERE participant.event_id IN (SELECT shop_event.id FROM public.active_shop_events_v2 AS shop_event WHERE shop_event.shop_context_id = s.id)), '[]'::jsonb),
        (SELECT to_jsonb(notice) FROM public.shop_operating_notices AS notice WHERE notice.shop_id = s.id AND (notice.end_date IS NULL OR notice.end_date >= (current_timestamp AT TIME ZONE 'Asia/Seoul')::date) ORDER BY notice.notice_date DESC, notice.id LIMIT 1),
        coalesce((SELECT jsonb_agg(to_jsonb(section) ORDER BY CASE WHEN trim(section.title) = '상시메뉴' THEN 1 ELSE 0 END, section.display_order, section.id) FROM public.shop_menu_sections AS section WHERE section.shop_id = s.id AND section.is_visible), '[]'::jsonb),
        coalesce((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.display_order, item.id) FROM public.visible_shop_menu_items AS item WHERE item.shop_id = s.id), '[]'::jsonb)
    FROM public.ramen_shops AS s
    WHERE s.id = p_shop_id;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_rankings(
    p_area text,
    p_category_ids text[],
    p_cursor_like_count bigint,
    p_cursor_name text,
    p_cursor_id uuid,
    p_limit integer
)
RETURNS TABLE(
    id uuid,
    kakao_place_id varchar,
    name varchar,
    address text,
    lat numeric,
    lng numeric,
    kakao_place_url text,
    naver_place_url text,
    phone varchar,
    business_hours text,
    instagram_url varchar,
    instagram_profile_image_path text,
    kakao_rating numeric,
    menu_category_ids text[],
    is_visible boolean,
    created_at timestamptz,
    updated_at timestamptz,
    like_count bigint
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
    SELECT
        shops.id,
        substring(shops.kakao_place_url FROM '^https?://place\.map\.kakao\.com/([0-9]+)([/?#]|$)')::varchar,
        shops.name,
        shops.address,
        shops.lat,
        shops.lng,
        shops.kakao_place_url,
        shops.naver_place_url,
        NULL::varchar,
        shops.business_hours,
        shops.instagram_url,
        shops.instagram_profile_image_path,
        NULL::numeric,
        shops.menu_category_ids,
        shops.is_visible,
        shops.created_at,
        shops.updated_at,
        counts.like_count
    FROM public.ramen_shops AS shops
    JOIN public.shop_bookmark_counts AS counts ON counts.shop_id = shops.id
    WHERE shops.is_visible = true
      AND counts.like_count > 0
      AND (
          p_area IS NULL
          OR CASE split_part(btrim(shops.address), ' ', 1)
              WHEN '서울' THEN 'SEOUL'
              WHEN '서울특별시' THEN 'SEOUL'
              WHEN '부산' THEN 'BUSAN'
              WHEN '부산광역시' THEN 'BUSAN'
              WHEN '대구' THEN 'DAEGU'
              WHEN '대구광역시' THEN 'DAEGU'
              WHEN '인천' THEN 'INCHEON'
              WHEN '인천광역시' THEN 'INCHEON'
              WHEN '광주' THEN 'GWANGJU'
              WHEN '광주광역시' THEN 'GWANGJU'
              WHEN '대전' THEN 'DAEJEON'
              WHEN '대전광역시' THEN 'DAEJEON'
              WHEN '울산' THEN 'ULSAN'
              WHEN '울산광역시' THEN 'ULSAN'
              WHEN '세종' THEN 'SEJONG'
              WHEN '세종특별자치시' THEN 'SEJONG'
              WHEN '경기' THEN 'GYEONGGI'
              WHEN '경기도' THEN 'GYEONGGI'
              WHEN '충북' THEN 'CHUNGBUK'
              WHEN '충청북도' THEN 'CHUNGBUK'
              WHEN '충남' THEN 'CHUNGNAM'
              WHEN '충청남도' THEN 'CHUNGNAM'
              WHEN '전남' THEN 'JEONNAM'
              WHEN '전라남도' THEN 'JEONNAM'
              WHEN '경북' THEN 'GYEONGBUK'
              WHEN '경상북도' THEN 'GYEONGBUK'
              WHEN '경남' THEN 'GYEONGNAM'
              WHEN '경상남도' THEN 'GYEONGNAM'
              WHEN '강원' THEN 'GANGWON'
              WHEN '강원도' THEN 'GANGWON'
              WHEN '강원특별자치도' THEN 'GANGWON'
              WHEN '전북' THEN 'JEONBUK'
              WHEN '전라북도' THEN 'JEONBUK'
              WHEN '전북특별자치도' THEN 'JEONBUK'
              WHEN '제주' THEN 'JEJU'
              WHEN '제주도' THEN 'JEJU'
              WHEN '제주특별자치도' THEN 'JEJU'
              ELSE NULL
          END = p_area
      )
      AND (coalesce(cardinality(p_category_ids), 0) = 0 OR shops.menu_category_ids && p_category_ids)
      AND (
          (p_cursor_like_count IS NULL AND p_cursor_name IS NULL AND p_cursor_id IS NULL)
          OR counts.like_count < p_cursor_like_count
          OR (counts.like_count = p_cursor_like_count AND shops.name > p_cursor_name)
          OR (counts.like_count = p_cursor_like_count AND shops.name = p_cursor_name AND shops.id > p_cursor_id)
      )
    ORDER BY counts.like_count DESC, shops.name ASC, shops.id ASC
    LIMIT least(greatest(coalesce(p_limit, 20), 1), 50) + 1;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_rankings(
    p_area text,
    p_sigungu text,
    p_category_ids text[],
    p_cursor_like_count bigint,
    p_cursor_name text,
    p_cursor_id uuid,
    p_limit integer
)
RETURNS TABLE(
    id uuid,
    kakao_place_id varchar,
    name varchar,
    address text,
    lat numeric,
    lng numeric,
    kakao_place_url text,
    naver_place_url text,
    phone varchar,
    business_hours text,
    instagram_url varchar,
    instagram_profile_image_path text,
    menu_category_ids text[],
    is_visible boolean,
    created_at timestamptz,
    updated_at timestamptz,
    like_count bigint
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
    WITH candidates AS (
        SELECT
            shops.*,
            substring(shops.kakao_place_url FROM '^https?://place\.map\.kakao\.com/([0-9]+)([/?#]|$)')::varchar AS kakao_place_id,
            NULL::varchar AS phone,
            coalesce(counts.like_count, 0)::bigint AS normalized_like_count,
            split_part(btrim(shops.address), ' ', 2) AS normalized_sigungu,
            CASE split_part(btrim(shops.address), ' ', 1)
                WHEN '서울' THEN 'SEOUL'
                WHEN '서울특별시' THEN 'SEOUL'
                WHEN '부산' THEN 'BUSAN'
                WHEN '부산광역시' THEN 'BUSAN'
                WHEN '대구' THEN 'DAEGU'
                WHEN '대구광역시' THEN 'DAEGU'
                WHEN '인천' THEN 'INCHEON'
                WHEN '인천광역시' THEN 'INCHEON'
                WHEN '광주' THEN 'GWANGJU'
                WHEN '광주광역시' THEN 'GWANGJU'
                WHEN '대전' THEN 'DAEJEON'
                WHEN '대전광역시' THEN 'DAEJEON'
                WHEN '울산' THEN 'ULSAN'
                WHEN '울산광역시' THEN 'ULSAN'
                WHEN '세종' THEN 'SEJONG'
                WHEN '세종특별자치시' THEN 'SEJONG'
                WHEN '경기' THEN 'GYEONGGI'
                WHEN '경기도' THEN 'GYEONGGI'
                WHEN '충북' THEN 'CHUNGBUK'
                WHEN '충청북도' THEN 'CHUNGBUK'
                WHEN '충남' THEN 'CHUNGNAM'
                WHEN '충청남도' THEN 'CHUNGNAM'
                WHEN '전남' THEN 'JEONNAM'
                WHEN '전라남도' THEN 'JEONNAM'
                WHEN '전남광주통합특별시' THEN 'JEONNAM'
                WHEN '경북' THEN 'GYEONGBUK'
                WHEN '경상북도' THEN 'GYEONGBUK'
                WHEN '경남' THEN 'GYEONGNAM'
                WHEN '경상남도' THEN 'GYEONGNAM'
                WHEN '강원' THEN 'GANGWON'
                WHEN '강원도' THEN 'GANGWON'
                WHEN '강원특별자치도' THEN 'GANGWON'
                WHEN '전북' THEN 'JEONBUK'
                WHEN '전라북도' THEN 'JEONBUK'
                WHEN '전북특별자치도' THEN 'JEONBUK'
                WHEN '제주' THEN 'JEJU'
                WHEN '제주도' THEN 'JEJU'
                WHEN '제주특별자치도' THEN 'JEJU'
                ELSE NULL
            END AS normalized_area
        FROM public.ramen_shops AS shops
        LEFT JOIN public.shop_bookmark_counts AS counts ON counts.shop_id = shops.id
        WHERE shops.is_visible = true
    )
    SELECT
        candidates.id,
        candidates.kakao_place_id,
        candidates.name,
        candidates.address,
        candidates.lat,
        candidates.lng,
        candidates.kakao_place_url,
        candidates.naver_place_url,
        candidates.phone,
        candidates.business_hours,
        candidates.instagram_url,
        candidates.instagram_profile_image_path,
        candidates.menu_category_ids,
        candidates.is_visible,
        candidates.created_at,
        candidates.updated_at,
        candidates.normalized_like_count
    FROM candidates
    WHERE (p_area IS NULL OR candidates.normalized_area = p_area)
      AND (p_sigungu IS NULL OR (candidates.normalized_sigungu ~ '(시|군|구)$' AND candidates.normalized_sigungu = p_sigungu))
      AND (coalesce(cardinality(p_category_ids), 0) = 0 OR candidates.menu_category_ids && p_category_ids)
      AND (
          (p_cursor_like_count IS NULL AND p_cursor_name IS NULL AND p_cursor_id IS NULL)
          OR candidates.normalized_like_count < p_cursor_like_count
          OR (candidates.normalized_like_count = p_cursor_like_count AND candidates.name > p_cursor_name)
          OR (candidates.normalized_like_count = p_cursor_like_count AND candidates.name = p_cursor_name AND candidates.id > p_cursor_id)
      )
    ORDER BY candidates.normalized_like_count DESC, candidates.name ASC, candidates.id ASC
    LIMIT least(greatest(coalesce(p_limit, 20), 1), 50) + 1;
$function$;

-- The candidate table and its only trigger were removed in an earlier migration;
-- this orphan trigger function is no longer callable or needed.
DROP FUNCTION IF EXISTS public.notify_discord_operating_notice_candidate() RESTRICT;

DROP VIEW public.shops RESTRICT;

COMMIT;
