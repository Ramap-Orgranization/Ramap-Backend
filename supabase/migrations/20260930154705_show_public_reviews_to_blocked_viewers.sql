-- Public shop reviews remain visible to users blocked by their authors.
-- A viewer's own blocks still mask the review contents in the response.

CREATE OR REPLACE FUNCTION public.fetch_shop_reviews(p_shop_id uuid, p_offset bigint DEFAULT 0)
 RETURNS TABLE(id uuid, shop_id uuid, body text, created_at timestamp with time zone, image_paths text[], user_id uuid, nickname text, avatar_path text, moderation_status text, is_public boolean, is_blocked boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid := auth.uid();
begin
    if p_shop_id is null or p_offset is null or p_offset < 0 then
        raise exception 'Invalid review page';
    end if;

    return query
    select r.id, r.shop_id,
           case when b.blocked_id is not null then ''::text else r.body end,
           r.created_at,
           case when b.blocked_id is not null then array[]::text[] else r.image_paths end,
           r.user_id,
           case when b.blocked_id is not null then ''::text else p.nickname end,
           case when b.blocked_id is not null then null::text else p.avatar_path end,
           r.moderation_status, r.is_public, b.blocked_id is not null
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
                  select 1 from public.account_deletion_requests d
                  where d.user_id = r.user_id
              )
          )
      )
    order by r.created_at desc, r.id desc limit 20 offset p_offset;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fetch_shop_reviews_page(p_shop_id uuid, p_offset bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid := auth.uid();
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
                    select r2.id, r2.shop_id,
                           case when b2.blocked_id is not null then ''::text else r2.body end as body,
                           r2.created_at,
                           case when b2.blocked_id is not null then array[]::text[] else r2.image_paths end as image_paths,
                           r2.user_id,
                           case when b2.blocked_id is not null then ''::text else p2.nickname end as nickname,
                           case when b2.blocked_id is not null then null::text else p2.avatar_path end as avatar_path,
                           r2.moderation_status, r2.is_public,
                           b2.blocked_id is not null as is_blocked
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
                                  select 1 from public.account_deletion_requests d2
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
                      select 1 from public.account_deletion_requests d
                      where d.user_id = r.user_id
                  )
              )
          )
    );
end;
$function$;
