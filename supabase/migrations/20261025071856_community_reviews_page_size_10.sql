create or replace function public.fetch_community_reviews_page(
    p_created_at timestamptz default null,
    p_review_id uuid default null
)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $function$
declare
    viewer uuid := auth.uid();
    result jsonb;
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
               r.moderation_status, r.is_public, r.visit_number, r.is_blocked,
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
    return result;
end;
$function$;
