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
                           case when b2.blocked_id is null then (
                               select count(*)::integer from public.review_likes l where l.review_id = r2.id
                           ) else 0 end as like_count,
                           b2.blocked_id is null and exists (
                               select 1 from public.review_likes l
                               where l.review_id = r2.id and l.user_id = current_user_id
                           ) as is_liked,
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
