-- Include stored visit ordinals and actual likes in owner-only review projections.
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
                           r2.visit_number,
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
                   r.moderation_note, r.is_public, r.visit_number,
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

REVOKE ALL ON FUNCTION public.fetch_my_reviews(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fetch_my_review(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fetch_my_reviews(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fetch_my_review(uuid) TO authenticated;
