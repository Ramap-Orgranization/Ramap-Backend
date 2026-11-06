-- Preserve earlier profile APIs and enrich only the already-authorized page.
create function public.fetch_profile_reviews_page_v4(p_user_id uuid, p_offset bigint default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
    viewer uuid := auth.uid();
    page jsonb;
    rows jsonb;
begin
    page := public.fetch_profile_reviews_page_v3(p_user_id, p_offset);
    select coalesce(jsonb_agg(
        jsonb_set(
            r.entry,
            '{review}',
            (r.entry -> 'review') || jsonb_build_object(
                'like_count', likes.like_count,
                'is_liked', likes.is_liked
            )
        ) order by r.ordinality
    ), '[]'::jsonb)
    into rows
    from jsonb_array_elements(page -> 'reviews') with ordinality as r(entry, ordinality)
    cross join lateral (
        select count(*)::integer as like_count,
               coalesce(bool_or(l.user_id = viewer), false) as is_liked
        from public.review_likes l
        where l.review_id = (r.entry -> 'review' ->> 'id')::uuid
    ) likes;
    return jsonb_set(page, '{reviews}', rows);
end;
$function$;

revoke all on function public.fetch_profile_reviews_page_v4(uuid, bigint) from public;
grant execute on function public.fetch_profile_reviews_page_v4(uuid, bigint) to anon, authenticated;
