begin;

create or replace function community_private.fetch_profile_visit_ranking(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
    profile_access jsonb := community_private.fetch_profile_access(p_user_id);
    viewer_id uuid := auth.uid();
    shops jsonb;
begin
    if profile_access ->> 'status' is distinct from 'visible'
       or not coalesce((profile_access ->> 'can_read_reviews')::boolean, false) then
        return jsonb_build_object('available', false, 'shops', '[]'::jsonb);
    end if;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'shop_id', ranked.shop_id,
                'shop_name', ranked.shop_name,
                'visit_count', ranked.visit_count,
                'instagram_profile_image_path', ranked.instagram_profile_image_path
            ) order by ranked.visit_count desc, ranked.shop_name, ranked.shop_id
        ),
        '[]'::jsonb
    )
    into shops
    from (
        select s.id as shop_id, s.name as shop_name, count(*) as visit_count, s.instagram_profile_image_path
        from public.shop_reviews r
        join public.ramen_shops s on s.id = r.shop_id and s.is_visible
        where r.user_id = p_user_id
          and (r.user_id = viewer_id or (r.is_public and r.moderation_status = 'published'))
        group by s.id, s.name, s.instagram_profile_image_path
        order by visit_count desc, shop_name, shop_id
        limit 10
    ) ranked;

    return jsonb_build_object('available', true, 'shops', shops);
end;
$function$;

commit;
