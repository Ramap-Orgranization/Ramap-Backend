begin;

-- Preserve the visit number assigned at creation in every review projection.
-- Function signatures, visibility predicates, counts and existing grants remain unchanged.

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
           r.visit_number
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
                           r2.visit_number
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
                           r2.visit_number
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
           r.visit_number
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
        'visit_number', r.visit_number,
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

commit;
