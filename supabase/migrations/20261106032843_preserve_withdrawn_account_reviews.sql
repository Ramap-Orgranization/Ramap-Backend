begin;

set local lock_timeout = '5s';

alter table public.shop_reviews
    alter column user_id drop not null,
    drop constraint shop_reviews_user_id_fkey,
    add constraint shop_reviews_user_id_fkey
        foreign key (user_id) references auth.users(id) on delete restrict;

create function media_private.is_withdrawn_review_photo(p_review_id uuid, p_path text)
returns boolean
language sql immutable
set search_path = ''
as $$
    select p_path ~ ('^withdrawn/' || p_review_id::text || '/[1-3][.](jpg|png)$');
$$;

alter table public.shop_reviews
    drop constraint shop_reviews_image_paths_owner,
    add constraint shop_reviews_image_paths_owner check (
        array_position(image_paths, null) is null
        and (
            (user_id is not null and public.shop_review_image_paths_belong_to_user(image_paths, user_id))
            or (
                media_private.is_withdrawn_review_photo(id, image_paths[1])
                and (cardinality(image_paths) < 2 or media_private.is_withdrawn_review_photo(id, image_paths[2]))
                and (cardinality(image_paths) < 3 or media_private.is_withdrawn_review_photo(id, image_paths[3]))
            )
            or cardinality(image_paths) = 0
        ) is true
    );

-- Paths contain the original user's UUID. Copy through the Storage API to a
-- path derived from the review, then switch references before deleting originals.
create function media_private.account_review_photos_to_preserve(p_user_id uuid)
returns table(review_id uuid, photo_order bigint, source_path text, destination_path text)
language sql stable
set search_path = ''
as $$
    select r.id, photo.ordinality, photo.path,
           'withdrawn/' || r.id::text || '/' || photo.ordinality || '.' || right(photo.path, 3)
    from public.shop_reviews r
    cross join lateral unnest(r.image_paths) with ordinality as photo(path, ordinality)
    where r.user_id = p_user_id
      and not media_private.is_withdrawn_review_photo(r.id, photo.path);
$$;

create function public.list_account_review_photo_copies(p_user_id uuid)
returns table(source_path text, destination_path text)
language plpgsql stable security definer
set search_path = ''
as $$
begin
    if auth.role() is distinct from 'service_role'
       or not exists (select 1 from public.account_deletion_requests where user_id = p_user_id)
    then raise insufficient_privilege; end if;

    return query
    select photo.source_path, photo.destination_path
    from media_private.account_review_photos_to_preserve(p_user_id) photo
    where not exists (
        select 1 from storage.objects o
        where o.bucket_id = 'shop-review-images' and o.name = photo.destination_path
          and o.owner is null and o.owner_id is null
    )
    order by photo.review_id, photo.photo_order
    limit 24;
end;
$$;

create or replace function public.prepare_account_media_cleanup(p_user_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare item media_private.objects;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    perform 1 from auth.users where id = p_user_id for update;
    if not found or not exists (select 1 from public.account_deletion_requests where user_id = p_user_id)
    then raise insufficient_privilege; end if;

    if exists (select 1 from public.list_account_review_photo_copies(p_user_id)) then
        raise exception 'Review photo copies are incomplete' using errcode = '55000';
    end if;

    with copies as (
        select photo.review_id, array_agg(photo.destination_path order by photo.photo_order) as paths
        from media_private.account_review_photos_to_preserve(p_user_id) photo
        group by photo.review_id
    )
    update public.shop_reviews r set image_paths = copies.paths
    from copies where r.id = copies.review_id;

    for item in
        select * from media_private.objects where owner_id = p_user_id and state <> 'deleted' order by path
    loop
        perform media_private.queue_delete(item.id);
    end loop;
end;
$$;

create or replace function public.list_account_owned_storage(p_user_id uuid)
returns table(bucket_id text, name text)
language plpgsql stable security definer
set search_path = ''
as $$
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    if p_user_id is null then raise exception 'Invalid user'; end if;
    if exists (select 1 from media_private.account_review_photos_to_preserve(p_user_id)) then
        raise exception 'Review photos must be preserved before storage cleanup' using errcode = '55000';
    end if;

    return query
    select o.bucket_id, o.name from storage.objects o
    where (o.bucket_id in ('shop-review-images', 'profile-avatars') and o.name like p_user_id::text || '/%')
       or o.owner = p_user_id
       or o.owner_id = p_user_id::text;
end;
$$;

create or replace function public.list_review_image_orphans(p_before timestamptz)
returns table(name text)
language plpgsql stable security definer
set search_path = ''
as $$
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    if p_before is null then raise exception 'A cutoff is required'; end if;
    return query
    select o.name from storage.objects o
    where o.bucket_id = 'shop-review-images' and o.created_at < p_before
      and not exists (select 1 from public.shop_reviews r where o.name = any(r.image_paths))
      and not exists (select 1 from public.community_reports r where o.name = any(r.review_image_paths_snapshot))
      and not exists (
          select 1 from public.shop_reviews r
          join public.account_deletion_requests d on d.user_id = r.user_id
          where r.id = case
              when o.name ~ '^withdrawn/[0-9a-f-]{36}/[1-3][.](jpg|png)$'
                   and pg_input_is_valid(split_part(o.name, '/', 2), 'uuid')
              then split_part(o.name, '/', 2)::uuid
          end
      );
end;
$$;

alter table public.community_reports
    alter column target_user_id drop not null,
    add constraint community_reports_user_target_required
        check (target_type = 'review' or target_user_id is not null);

create function community_private.preserve_reviews_on_account_delete()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare profile_was_public boolean;
begin
    if not exists (select 1 from public.shop_reviews where user_id = old.id) then return old; end if;
    if exists (select 1 from media_private.account_review_photos_to_preserve(old.id)) then
        raise exception 'Review photos must be preserved before account deletion' using errcode = '55000';
    end if;

    select exists (
        select 1 from public.public_profiles p
        where p.user_id = old.id and p.is_public and p.suspended_at is null
    ) into profile_was_public;

    with visits as (
        select id, row_number() over (partition by shop_id order by visit_number)::integer as visit_number
        from public.shop_reviews where user_id = old.id
    )
    update public.shop_reviews r
    set user_id = null, is_public = r.is_public and profile_was_public, visit_number = visits.visit_number
    from visits where r.id = visits.id;

    -- Keep pending moderation attached to surviving content and remove account snapshots.
    update public.community_reports
    set target_user_id = null, profile_nickname_snapshot = '탈퇴한 사용자',
        profile_bio_snapshot = null, profile_avatar_path_snapshot = null,
        review_image_paths_snapshot = null
    where target_user_id = old.id and target_type = 'review' and review_id is not null;

    return old;
end;
$$;

create trigger preserve_reviews_on_account_delete
before delete on auth.users
for each row execute function community_private.preserve_reviews_on_account_delete();

revoke all on function media_private.account_review_photos_to_preserve(uuid),
    public.list_account_review_photo_copies(uuid),
    community_private.preserve_reviews_on_account_delete() from public, anon, authenticated;
grant execute on function public.list_account_review_photo_copies(uuid) to service_role;

-- Keep the stored author nullable. The review RPCs serialize it as an empty
-- string so released apps disable profile navigation with their existing guard.
create or replace function community_private.count_review_visits(
    p_user_id uuid, p_shop_id uuid, p_visit_number integer
)
returns integer
language sql stable
set search_path = ''
as $$
    select case when p_user_id is null then p_visit_number else (
        select count(*)::integer from public.shop_reviews r
        where r.user_id = p_user_id and r.shop_id = p_shop_id and r.visit_number <= p_visit_number
    ) end;
$$;

create or replace function community_private.can_read_review_image(p_path text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select (
        auth.uid() is not null
        and split_part(p_path, '/', 1) = auth.uid()::text
        and community_private.has_live_user()
    ) or exists (
        select 1 from public.shop_reviews r
        where p_path = any(r.image_paths)
          and r.moderation_status = 'published'
          and r.is_public
          and (
              (r.user_id is null and exists (select 1 from public.ramen_shops s where s.id = r.shop_id and s.is_visible))
              or public.fetch_public_community_profile(r.user_id) is not null
              or community_private.can_view_blocked_review_once(r.id)
              or community_private.can_read_follow_content(r.user_id, 'reviews')
          )
    );
$$;

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
        left join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        where r.is_public and r.moderation_status = 'published'
          and (r.user_id is null or (p.is_public and p.suspended_at is null))
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
               coalesce(r.user_id::text, '') as user_id,
               r.user_id is null as is_withdrawn,
               case when r.is_blocked then ''::text when r.user_id is null then '탈퇴한 사용자'::text else r.nickname end as nickname,
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
        left join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        cross join lateral (
            select count(*)::integer as like_count
            from public.review_likes l where l.review_id = r.id
        ) likes
        where r.is_public and r.moderation_status = 'published'
          and (r.user_id is null or (p.is_public and p.suspended_at is null))
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
               coalesce(r.user_id::text, '') as user_id,
               r.user_id is null as is_withdrawn,
               case when r.is_blocked then ''::text when r.user_id is null then '탈퇴한 사용자'::text else r.nickname end as nickname,
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
        left join public.public_profiles p on p.user_id = r.user_id
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        cross join lateral (
            select count(*)::integer as like_count
            from public.review_likes l where p_sort = 'popular' and l.review_id = r.id
        ) likes
        where r.is_public and r.moderation_status = 'published'
          and (r.user_id is null or (p.is_public and p.suspended_at is null))
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
               coalesce(r.user_id::text, '') as user_id,
               r.user_id is null as is_withdrawn,
               case when r.is_blocked then ''::text when r.user_id is null then '탈퇴한 사용자'::text else r.nickname end as nickname,
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

-- PostgreSQL requires a replacement when an OUT column changes type.
DROP FUNCTION public.fetch_shop_reviews(uuid, bigint);
CREATE FUNCTION public.fetch_shop_reviews(p_shop_id uuid, p_offset bigint DEFAULT 0)
 RETURNS TABLE(id uuid, shop_id uuid, body text, created_at timestamp with time zone, image_paths text[], user_id text, nickname text, avatar_path text, moderation_status text, is_public boolean, is_blocked boolean, author_review_count integer, visit_number integer, is_withdrawn boolean)
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
           coalesce(r.user_id::text, '') as user_id,
           case when b.blocked_id is not null then ''::text when r.user_id is null then '탈퇴한 사용자'::text else p.nickname end,
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
           community_private.count_review_visits(r.user_id, r.shop_id, r.visit_number) as visit_number,
           r.user_id is null as is_withdrawn
    from public.shop_reviews r
    left join public.public_profiles p on p.user_id = r.user_id
    left join public.user_blocks b
      on b.blocker_id = current_user_id and b.blocked_id = r.user_id
    where r.shop_id = p_shop_id
      and (
          r.user_id = current_user_id
          or (
              r.is_public
              and r.moderation_status = 'published'
              and ((r.user_id is null and exists (select 1 from public.ramen_shops s where s.id = r.shop_id and s.is_visible)) or (p.is_public and p.suspended_at is null))
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

REVOKE ALL ON FUNCTION public.fetch_shop_reviews(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fetch_shop_reviews(uuid, bigint) TO anon, authenticated, service_role;

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
                           coalesce(r2.user_id::text, '') as user_id,
                           r2.user_id is null as is_withdrawn,
                           case when b2.blocked_id is not null then ''::text when r2.user_id is null then '탈퇴한 사용자'::text else p2.nickname end as nickname,
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
                    left join public.public_profiles p2 on p2.user_id = r2.user_id
                    left join public.user_blocks b2
                      on b2.blocker_id = current_user_id and b2.blocked_id = r2.user_id
                    where r2.shop_id = p_shop_id
                      and (
                          r2.user_id = current_user_id
                          or (
                              r2.is_public
                              and r2.moderation_status = 'published'
                              and ((r2.user_id is null and exists (select 1 from public.ramen_shops s where s.id = r2.shop_id and s.is_visible)) or (p2.is_public and p2.suspended_at is null))
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
        left join public.public_profiles p on p.user_id = r.user_id
        where r.shop_id = p_shop_id
          and (
              r.user_id = current_user_id
              or (
                  r.is_public
                  and r.moderation_status = 'published'
                  and ((r.user_id is null and exists (select 1 from public.ramen_shops s where s.id = r.shop_id and s.is_visible)) or (p.is_public and p.suspended_at is null))
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

CREATE OR REPLACE FUNCTION public.set_review_like(p_review_id uuid, p_liked boolean)
 RETURNS TABLE(like_count integer, is_liked boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
declare target_user_id uuid;
declare target_shop_id uuid;
declare target_is_public boolean;
declare target_moderation_status text;
begin
    current_user_id := community_private.require_live_user();
    if p_review_id is null or p_liked is null then raise exception 'Invalid review like'; end if;
    select r.user_id, r.shop_id, r.is_public, r.moderation_status
    into target_user_id, target_shop_id, target_is_public, target_moderation_status
    from public.shop_reviews r where r.id = p_review_id for share;
    if not found or target_user_id = current_user_id or not target_is_public
       or target_moderation_status <> 'published'
       or not (case when target_user_id is null then
           exists (select 1 from public.ramen_shops s where s.id = target_shop_id and s.is_visible)
       else community_private.can_view_public_profile(target_user_id) end)
    then
        raise exception 'Invalid review like';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(p_review_id::text || ':' || current_user_id::text, 0));
    if p_liked then
        insert into public.review_likes(review_id, user_id)
        values (p_review_id, current_user_id) on conflict do nothing;
    else
        delete from public.review_likes l
        where l.review_id = p_review_id and l.user_id = current_user_id;
    end if;
    return query select count(*)::integer, exists (
        select 1 from public.review_likes l
        where l.review_id = p_review_id and l.user_id = current_user_id
    ) from public.review_likes l where l.review_id = p_review_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.report_community_content(p_target_type text, p_target_id uuid, p_reason text, p_details text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    current_user_id uuid;
    target_user_id uuid;
    target_review public.shop_reviews%rowtype;
    target_nickname text;
    target_bio text;
    target_avatar_path text;
begin
    current_user_id := community_private.require_live_user();
    if p_target_type not in ('review', 'user') or p_target_id is null
       or p_reason not in ('spam', 'harassment', 'hate', 'sexual_content', 'violence', 'privacy', 'other')
       or p_details is null or p_details <> btrim(p_details) or char_length(p_details) > 1000
    then
        raise exception 'Invalid report';
    end if;
    if p_target_type = 'review' then
        select * into target_review from public.shop_reviews
        where id = p_target_id and moderation_status = 'published' and is_public;
        if not found or not (
            (target_review.user_id is null and exists (
                select 1 from public.ramen_shops s where s.id = target_review.shop_id and s.is_visible
            ))
            or community_private.can_view_public_profile(target_review.user_id)
            or community_private.can_view_blocked_review_once(target_review.id)
        ) then
            raise exception 'Invalid report target';
        end if;
        target_user_id := target_review.user_id;
        select nickname, bio, avatar_path into target_nickname, target_bio, target_avatar_path
        from public.public_profiles where user_id = target_user_id;
        if target_user_id is null then target_nickname := '탈퇴한 사용자'; end if;
    else
        target_user_id := p_target_id;
        select nickname, bio, avatar_path into target_nickname, target_bio, target_avatar_path
        from public.public_profiles where user_id = target_user_id;
        if target_nickname is null or not (
            community_private.can_view_public_profile(target_user_id)
            or exists (select 1 from public.user_blocks where blocker_id = current_user_id and blocked_id = target_user_id)
        ) then
            raise exception 'Invalid report target';
        end if;
    end if;
    if target_user_id = current_user_id then raise exception 'Invalid report target'; end if;
    insert into public.community_reports(
        reporter_id, target_user_id, review_id, target_type, target_id, reason, details,
        review_body_snapshot, review_image_paths_snapshot, profile_nickname_snapshot, profile_bio_snapshot, profile_avatar_path_snapshot
    ) values (
        current_user_id, target_user_id, target_review.id, p_target_type, p_target_id, p_reason, p_details,
        target_review.body, target_review.image_paths, target_nickname, target_bio, target_avatar_path
    ) on conflict (reporter_id, target_type, target_id) where status = 'pending' do nothing;
end;
$function$;

commit;
