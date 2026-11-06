begin;

-- Stored ordinals remain monotonic for concurrent inserts. Displayed visits count
-- only reviews that still exist, including private and moderated reviews.
create function community_private.count_review_visits(
    p_user_id uuid,
    p_shop_id uuid,
    p_visit_number integer
)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
    select count(*)::integer
    from public.shop_reviews r
    where r.user_id = p_user_id
      and r.shop_id = p_shop_id
      and r.visit_number <= p_visit_number;
$$;
revoke all on function community_private.count_review_visits(uuid, uuid, integer)
    from public, anon, authenticated;

-- Keep each RPC's visibility, pagination, counts and grants unchanged.

CREATE OR REPLACE FUNCTION public.fetch_review_feed_page(p_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_review_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    viewer uuid := auth.uid();
    result jsonb;
    rows jsonb;
begin
    if (p_created_at is null) <> (p_review_id is null)
       or (p_created_at is not null and not pg_catalog.isfinite(p_created_at)) then
        raise exception 'Invalid community cursor' using errcode = '22023';
    end if;

    with eligible as materialized (
        select r.*, p.nickname, p.avatar_path,
               exists (
                   select 1 from public.user_blocks b
                   where b.blocker_id = viewer and b.blocked_id = r.user_id
               ) as is_blocked
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        where r.is_public and r.moderation_status = 'published'
          and p.is_public and p.suspended_at is null
          and not exists (
              select 1 from public.account_deletion_requests d where d.user_id = r.user_id
          )
          and (p_created_at is null or (r.created_at, r.id) < (p_created_at, p_review_id))
        order by r.created_at desc, r.id desc
        limit 11
    ), page as materialized (
        select * from eligible order by created_at desc, id desc limit 10
    ), payload as (
        select r.id, r.shop_id,
               case when r.is_blocked then ''::text else r.body end as body,
               r.created_at,
               case when r.is_blocked then array[]::text[] else r.image_paths end as image_paths,
               r.user_id,
               case when r.is_blocked then ''::text else r.nickname end as nickname,
               case when r.is_blocked then null::text else r.avatar_path end as avatar_path,
               r.moderation_status, r.is_public, community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number, r.is_blocked,
               (select count(*)::integer from public.review_likes l where l.review_id = r.id) as like_count,
               exists (
                   select 1 from public.review_likes l where l.review_id = r.id and l.user_id = viewer
               ) as is_liked,
               (select count(*)::integer from public.shop_reviews a
                where a.user_id = r.user_id and a.is_public and a.moderation_status = 'published') as author_review_count
        from page r
    )
    select jsonb_build_object(
        'reviews', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc, p.id desc) from payload p), '[]'::jsonb),
        'next_created_at', case when (select count(*) from eligible) > 10
            then (select created_at from page order by created_at, id limit 1) end,
        'next_review_id', case when (select count(*) from eligible) > 10
            then (select id from page order by created_at, id limit 1) end
    ) into result;
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'review', r.review,
            'shop', case when s.id is not null then jsonb_build_object(
                'id', s.id,
                'name', s.name,
                'address', s.address,
                'lat', s.lat,
                'lng', s.lng,
                'kakao_place_url', s.kakao_place_url,
                'naver_place_url', s.naver_place_url,
                'waiting_provider', s.waiting_provider,
                'waiting_provider_url', s.waiting_provider_url,
                'business_hours_weekly', s.business_hours_weekly,
                'business_hours_break_times', s.business_hours_break_times,
                'business_hours_last_orders', s.business_hours_last_orders,
                'business_hours_notice', s.business_hours_notice,
                'business_hours_notice_type', s.business_hours_notice_type,
                'instagram_url', s.instagram_url,
                'instagram_profile_image_path', s.instagram_profile_image_path,
                'menu_category_ids', s.menu_category_ids,
                'is_visible', s.is_visible,
                'created_at', s.created_at,
                'updated_at', s.updated_at
            ) end
        ) order by r.ordinality
    ), '[]'::jsonb)
    into rows
    from jsonb_array_elements(result -> 'reviews') with ordinality as r(review, ordinality)
    left join public.ramen_shops s on s.id = (r.review ->> 'shop_id')::uuid;

    -- Never return a partial page if a shop cannot be read; preserve cursor/offset semantics.
    if exists (select 1 from jsonb_array_elements(rows) r where r -> 'shop' = 'null'::jsonb) then
        raise exception 'Review shop unavailable' using errcode = '42501';
    end if;
    return jsonb_set(result, '{reviews}', rows);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_popular_review_feed_page(p_like_count integer DEFAULT NULL::integer, p_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_review_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    viewer uuid := auth.uid();
    result jsonb;
begin
    if (p_created_at is null) <> (p_review_id is null)
       or (p_created_at is null) <> (p_like_count is null)
       or p_like_count < 0
       or (p_created_at is not null and not pg_catalog.isfinite(p_created_at)) then
        raise exception 'Invalid popular community cursor' using errcode = '22023';
    end if;

    with eligible as materialized (
        select r.*, p.nickname, p.avatar_path, likes.like_count,
               exists (
                   select 1 from public.user_blocks b
                   where b.blocker_id = viewer and b.blocked_id = r.user_id
               ) as is_blocked
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        cross join lateral (
            select count(*)::integer as like_count
            from public.review_likes l where l.review_id = r.id
        ) likes
        where r.is_public and r.moderation_status = 'published'
          and p.is_public and p.suspended_at is null
          and not exists (
              select 1 from public.account_deletion_requests d where d.user_id = r.user_id
          )
          and (p_created_at is null or (likes.like_count, r.created_at, r.id) < (p_like_count, p_created_at, p_review_id))
        order by likes.like_count desc, r.created_at desc, r.id desc
        limit 11
    ), page as materialized (
        select * from eligible order by like_count desc, created_at desc, id desc limit 10
    ), payload as (
        select r.id, r.shop_id,
               case when r.is_blocked then ''::text else r.body end as body,
               r.created_at,
               case when r.is_blocked then array[]::text[] else r.image_paths end as image_paths,
               r.user_id,
               case when r.is_blocked then ''::text else r.nickname end as nickname,
               case when r.is_blocked then null::text else r.avatar_path end as avatar_path,
               r.moderation_status, r.is_public, community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number, r.is_blocked,
               r.like_count,
               exists (
                   select 1 from public.review_likes l where l.review_id = r.id and l.user_id = viewer
               ) as is_liked,
               (select count(*)::integer from public.shop_reviews a
                where a.user_id = r.user_id and a.is_public and a.moderation_status = 'published') as author_review_count,
               jsonb_build_object(
                   'id', s.id,
                   'name', s.name,
                   'address', s.address,
                   'lat', s.lat,
                   'lng', s.lng,
                   'kakao_place_url', s.kakao_place_url,
                   'naver_place_url', s.naver_place_url,
                   'waiting_provider', s.waiting_provider,
                   'waiting_provider_url', s.waiting_provider_url,
                   'business_hours_weekly', s.business_hours_weekly,
                   'business_hours_break_times', s.business_hours_break_times,
                   'business_hours_last_orders', s.business_hours_last_orders,
                   'business_hours_notice', s.business_hours_notice,
                   'business_hours_notice_type', s.business_hours_notice_type,
                   'instagram_url', s.instagram_url,
                   'instagram_profile_image_path', s.instagram_profile_image_path,
                   'menu_category_ids', s.menu_category_ids,
                   'is_visible', s.is_visible,
                   'created_at', s.created_at,
                   'updated_at', s.updated_at
               ) as shop
        from page r
        join public.ramen_shops s on s.id = r.shop_id
    )
    select jsonb_build_object(
        'reviews', coalesce((select jsonb_agg(jsonb_build_object('review', to_jsonb(p) - 'shop', 'shop', p.shop) order by p.like_count desc, p.created_at desc, p.id desc) from payload p), '[]'::jsonb),
        'next_like_count', case when (select count(*) from eligible) > 10
            then (select like_count from page order by like_count, created_at, id limit 1) end,
        'next_created_at', case when (select count(*) from eligible) > 10
            then (select created_at from page order by like_count, created_at, id limit 1) end,
        'next_review_id', case when (select count(*) from eligible) > 10
            then (select id from page order by like_count, created_at, id limit 1) end
    ) into result;
    return result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_reviews(p_shop_id uuid, p_offset bigint DEFAULT 0)
 RETURNS TABLE(id uuid, shop_id uuid, body text, created_at timestamp with time zone, image_paths text[], user_id uuid, nickname text, avatar_path text, moderation_status text, is_public boolean, is_blocked boolean, author_review_count integer, visit_number integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    current_user_id uuid := auth.uid();
begin
    if p_shop_id is null or p_offset is null or p_offset < 0 then
        raise exception 'Invalid review page';
    end if;

    return query
    select r.id,
           r.shop_id,
           case when b.blocked_id is not null then ''::text else r.body end,
           r.created_at,
           case when b.blocked_id is not null then array[]::text[] else r.image_paths end,
           r.user_id,
           case when b.blocked_id is not null then ''::text else p.nickname end,
           case when b.blocked_id is not null then null::text else p.avatar_path end,
           r.moderation_status,
           r.is_public,
           b.blocked_id is not null,
           (
               select count(*)::integer
               from public.shop_reviews r_a
               where r_a.user_id = r.user_id
                 and r_a.is_public
                 and r_a.moderation_status = 'published'
           ) as author_review_count,
           community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number
    from public.shop_reviews r
    join public.public_profiles p on p.user_id = r.user_id
    left join public.user_blocks b
      on b.blocker_id = current_user_id and b.blocked_id = r.user_id
    where r.shop_id = p_shop_id
      and (
          r.user_id = current_user_id
          or (
              r.is_public
              and r.moderation_status = 'published'
              and p.is_public
              and p.suspended_at is null
              and not exists (
                  select 1
                  from public.account_deletion_requests d
                  where d.user_id = r.user_id
              )
          )
      )
    order by r.created_at desc, r.id desc
    limit 20 offset p_offset;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_reviews_page(p_shop_id uuid, p_offset bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    current_user_id uuid := auth.uid();
begin
    if p_shop_id is null or p_offset is null or p_offset < 0 then
        raise exception 'Invalid review page';
    end if;

    return (
        select jsonb_build_object(
            'total_count', count(*)::integer,
            'reviews', coalesce((
                select jsonb_agg(to_jsonb(page) order by page.created_at desc, page.id desc)
                from (
                    select r2.id,
                           r2.shop_id,
                           case when b2.blocked_id is not null then ''::text else r2.body end as body,
                           r2.created_at,
                           case when b2.blocked_id is not null then array[]::text[] else r2.image_paths end as image_paths,
                           r2.user_id,
                           case when b2.blocked_id is not null then ''::text else p2.nickname end as nickname,
                           case when b2.blocked_id is not null then null::text else p2.avatar_path end as avatar_path,
                           r2.moderation_status,
                           r2.is_public,
                           b2.blocked_id is not null as is_blocked,
                           (
                               select count(*)::integer
                               from public.shop_reviews r_a
                               where r_a.user_id = r2.user_id
                                 and r_a.is_public
                                 and r_a.moderation_status = 'published'
                           ) as author_review_count,
                           community_private.count_review_visits(r2.user_id, r2.shop_id, r2.visit_number) as visit_number
                    from public.shop_reviews r2
                    join public.public_profiles p2 on p2.user_id = r2.user_id
                    left join public.user_blocks b2
                      on b2.blocker_id = current_user_id and b2.blocked_id = r2.user_id
                    where r2.shop_id = p_shop_id
                      and (
                          r2.user_id = current_user_id
                          or (
                              r2.is_public
                              and r2.moderation_status = 'published'
                              and p2.is_public
                              and p2.suspended_at is null
                              and not exists (
                                  select 1
                                  from public.account_deletion_requests d2
                                  where d2.user_id = r2.user_id
                              )
                          )
                      )
                    order by r2.created_at desc, r2.id desc
                    limit 20 offset p_offset
                ) page
            ), '[]'::jsonb)
        )
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        where r.shop_id = p_shop_id
          and (
              r.user_id = current_user_id
              or (
                  r.is_public
                  and r.moderation_status = 'published'
                  and p.is_public
                  and p.suspended_at is null
                  and not exists (
                      select 1
                      from public.account_deletion_requests d
                      where d.user_id = r.user_id
                  )
              )
          )
    );
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_profile_reviews(p_user_id uuid DEFAULT NULL::uuid, p_offset bigint DEFAULT 0)
 RETURNS TABLE(id uuid, shop_id uuid, body text, created_at timestamp with time zone, image_paths text[], user_id uuid, nickname text, avatar_path text, moderation_status text, is_public boolean, author_review_count integer, visit_number integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    requested_user_id uuid := coalesce(p_user_id, auth.uid());
begin
    if requested_user_id is null or p_offset is null or p_offset < 0 then
        raise exception 'Invalid review page';
    end if;

    if requested_user_id is distinct from auth.uid()
       and public.fetch_public_community_profile(requested_user_id) is null
       and not community_private.can_read_follow_content(requested_user_id, 'reviews')
    then
        return;
    end if;

    return query
    select r.id,
           r.shop_id,
           r.body,
           r.created_at,
           r.image_paths,
           r.user_id,
           p.nickname,
           p.avatar_path,
           r.moderation_status,
           r.is_public,
           (
               select count(*)::integer
               from public.shop_reviews r_a
               where r_a.user_id = r.user_id
                 and r_a.is_public
                 and r_a.moderation_status = 'published'
           ) as author_review_count,
           community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number
    from public.shop_reviews r
    join public.public_profiles p on p.user_id = r.user_id
    where r.user_id = requested_user_id
      and (
          requested_user_id = auth.uid()
          or (r.is_public and r.moderation_status = 'published')
      )
    order by r.created_at desc, r.id desc
    limit 20 offset p_offset;
end;
$function$;

CREATE OR REPLACE FUNCTION community_private.review_mutation_snapshot(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
    select jsonb_build_object(
        'id', r.id,
        'shop_id', r.shop_id,
        'shop_name', s.name,
        'user_id', r.user_id,
        'nickname', coalesce(p.nickname, ''),
        'avatar_path', p.avatar_path,
        'body', r.body,
        'created_at', r.created_at,
        'image_paths', r.image_paths,
        'moderation_status', r.moderation_status,
        'moderation_note', r.moderation_note,
        'is_public', r.is_public,
        'is_blocked', false,
        'author_review_count', (
            select count(*)::integer from public.shop_reviews author_review
            where author_review.user_id = r.user_id
              and author_review.is_public
              and author_review.moderation_status = 'published'
        ),
        'visit_number', community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number),
        'like_count', (
            select count(*)::integer from public.review_likes review_like
            where review_like.review_id = r.id
        ),
        'is_liked', false
    )
    from public.shop_reviews r
    join public.ramen_shops s on s.id = r.shop_id
    left join public.public_profiles p on p.user_id = r.user_id
    where r.id = p_review_id and r.user_id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.fetch_blocked_shop_review_once(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
    select to_jsonb(review)
    from (
        select r.id, r.shop_id, r.body, r.created_at, r.image_paths,
               r.user_id, p.nickname, p.avatar_path, r.moderation_status, r.is_public,
               community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number,
               true as is_blocked
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        where r.id = p_review_id
          and community_private.can_view_blocked_review_once(r.id)
    ) review;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_my_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare owner_id uuid;
begin
    owner_id := community_private.require_live_user();
    if p_review_id is null then raise exception 'Invalid review'; end if;
    return (
        select to_jsonb(detail) from (
            select r.id, r.shop_id, s.name as shop_name, p.avatar_path,
                   r.body, r.created_at, r.image_paths, r.moderation_status,
                   r.moderation_note, r.is_public, community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number,
                   (
                       select count(*)::integer
                       from public.review_likes likes
                       where likes.review_id = r.id
                   ) as like_count
            from public.shop_reviews r
            join public.ramen_shops s on s.id = r.shop_id
            left join public.public_profiles p on p.user_id = r.user_id
            where r.id = p_review_id and r.user_id = owner_id
        ) detail
    );
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_my_reviews(p_offset bigint DEFAULT 0, p_visibility text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    owner_id uuid;
begin
    owner_id := community_private.require_live_user();
    if p_offset is null or p_offset < 0 or p_visibility is null or p_visibility not in ('all', 'public', 'private') then
        raise exception 'Invalid review page';
    end if;

    return (
        select jsonb_build_object(
            'total_count', count(*)::integer,
            'public_count', count(*) filter (where r.is_public)::integer,
            'private_count', count(*) filter (where not r.is_public)::integer,
            'profile_is_public', coalesce((select p.is_public from public.public_profiles p where p.user_id = owner_id), false),
            'reviews', coalesce((
                select jsonb_agg(to_jsonb(page) order by page.created_at desc, page.id desc)
                from (
                    select r2.id,
                           r2.shop_id,
                           s.name as shop_name,
                           p.avatar_path,
                           r2.body,
                           r2.created_at,
                           r2.image_paths,
                           r2.moderation_status,
                           r2.moderation_note,
                           r2.is_public,
                           (
                               select count(*)::integer
                               from public.shop_reviews r_a
                               where r_a.user_id = r2.user_id
                                 and r_a.is_public
                                 and r_a.moderation_status = 'published'
                           ) as author_review_count,
                           community_private.count_review_visits(r2.user_id, r2.shop_id, r2.visit_number) as visit_number,
                           (
                               select count(*)::integer
                               from public.review_likes likes
                               where likes.review_id = r2.id
                           ) as like_count
                    from public.shop_reviews r2
                    join public.ramen_shops s on s.id = r2.shop_id
                    left join public.public_profiles p on p.user_id = r2.user_id
                    where r2.user_id = owner_id
                      and (p_visibility = 'all' or r2.is_public = (p_visibility = 'public'))
                    order by r2.created_at desc, r2.id desc
                    limit 30 offset p_offset
                ) page
            ), '[]'::jsonb)
        )
        from public.shop_reviews r
        where r.user_id = owner_id
    );
end;
$function$;

CREATE OR REPLACE FUNCTION feed_private.fetch_filtered_review_feed_page(p_filter text, p_sort text DEFAULT 'latest'::text, p_like_count integer DEFAULT NULL::integer, p_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_review_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    viewer uuid := auth.uid();
    result jsonb;
begin
    if viewer is null or not exists (
        select 1 from public.public_profiles p
        where p.user_id = viewer and p.suspended_at is null
          and not exists (select 1 from public.account_deletion_requests d where d.user_id = viewer)
    ) then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if p_filter is null or p_filter not in ('saved_shops', 'following')
       or p_sort is null or p_sort not in ('latest', 'popular') then
        raise exception 'Invalid feed filter or sort' using errcode = '22023';
    end if;
    if (p_created_at is null) <> (p_review_id is null)
       or (p_sort = 'popular' and (p_created_at is null) <> (p_like_count is null))
       or (p_sort = 'latest' and p_like_count is not null)
       or p_like_count < 0
       or (p_created_at is not null and not pg_catalog.isfinite(p_created_at)) then
        raise exception 'Invalid filtered feed cursor' using errcode = '22023';
    end if;

    with eligible as materialized (
        select r.*, p.nickname, p.avatar_path, likes.like_count,
               exists (
                   select 1 from public.user_blocks b
                   where b.blocker_id = viewer and b.blocked_id = r.user_id
               ) as is_blocked
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        cross join lateral (
            select count(*)::integer as like_count
            from public.review_likes l where p_sort = 'popular' and l.review_id = r.id
        ) likes
        where r.is_public and r.moderation_status = 'published'
          and p.is_public and p.suspended_at is null
          and (
              (p_filter = 'saved_shops' and exists (
                  select 1 from public.user_shop_bookmarks b
                  where b.user_id = viewer and b.shop_id = r.shop_id
              ))
              or (p_filter = 'following' and exists (
                  select 1 from public.profile_follows f
                  where f.follower_id = viewer and f.followed_id = r.user_id and f.status = 'following'
              ))
          )
          and not exists (
              select 1 from public.account_deletion_requests d where d.user_id = r.user_id
          )
          and (p_created_at is null or (likes.like_count, r.created_at, r.id) < (case when p_sort = 'popular' then p_like_count else 0 end, p_created_at, p_review_id))
        order by likes.like_count desc, r.created_at desc, r.id desc
        limit 11
    ), page as materialized (
        select * from eligible order by like_count desc, created_at desc, id desc limit 10
    ), payload as (
        select r.id, r.shop_id,
               case when r.is_blocked then ''::text else r.body end as body,
               r.created_at,
               case when r.is_blocked then array[]::text[] else r.image_paths end as image_paths,
               r.user_id,
               case when r.is_blocked then ''::text else r.nickname end as nickname,
               case when r.is_blocked then null::text else r.avatar_path end as avatar_path,
               r.moderation_status, r.is_public, community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number, r.is_blocked,
               r.like_count as sort_like_count,
               case when p_sort = 'popular' then r.like_count
                    else (select count(*)::integer from public.review_likes l where l.review_id = r.id)
               end as like_count,
               exists (
                   select 1 from public.review_likes l where l.review_id = r.id and l.user_id = viewer
               ) as is_liked,
               (select count(*)::integer from public.shop_reviews a
                where a.user_id = r.user_id and a.is_public and a.moderation_status = 'published') as author_review_count,
               jsonb_build_object(
                   'id', s.id,
                   'name', s.name,
                   'address', s.address,
                   'lat', s.lat,
                   'lng', s.lng,
                   'kakao_place_url', s.kakao_place_url,
                   'naver_place_url', s.naver_place_url,
                   'waiting_provider', s.waiting_provider,
                   'waiting_provider_url', s.waiting_provider_url,
                   'business_hours_weekly', s.business_hours_weekly,
                   'business_hours_break_times', s.business_hours_break_times,
                   'business_hours_last_orders', s.business_hours_last_orders,
                   'business_hours_notice', s.business_hours_notice,
                   'business_hours_notice_type', s.business_hours_notice_type,
                   'instagram_url', s.instagram_url,
                   'instagram_profile_image_path', s.instagram_profile_image_path,
                   'menu_category_ids', s.menu_category_ids,
                   'is_visible', s.is_visible,
                   'created_at', s.created_at,
                   'updated_at', s.updated_at
               ) as shop
        from page r
        join public.ramen_shops s on s.id = r.shop_id
    )
    select jsonb_build_object(
        'reviews', coalesce((select jsonb_agg(jsonb_build_object('review', to_jsonb(p) - 'shop' - 'sort_like_count', 'shop', p.shop) order by p.sort_like_count desc, p.created_at desc, p.id desc) from payload p), '[]'::jsonb),
        'next_like_count', case when p_sort = 'popular' and (select count(*) from eligible) > 10
            then (select like_count from page order by like_count, created_at, id limit 1) end,
        'next_created_at', case when (select count(*) from eligible) > 10
            then (select created_at from page order by like_count, created_at, id limit 1) end,
        'next_review_id', case when (select count(*) from eligible) > 10
            then (select id from page order by like_count, created_at, id limit 1) end
    ) into result;
    return result;
end;
$function$;

commit;
