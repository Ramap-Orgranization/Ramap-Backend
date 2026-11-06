begin;

-- Keep bookmark table RLS owner-only; this endpoint exposes only the public projection.
create or replace function community_private.fetch_profile_saved_shops(
    p_user_id uuid,
    p_offset bigint default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    profile_access jsonb;
    saved_shops jsonb;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authentication required';
    end if;
    if p_user_id is null or p_offset is null or p_offset < 0 then
        raise exception using errcode = '22023', message = 'Invalid saved shop page';
    end if;

    profile_access := community_private.fetch_profile_access(p_user_id);
    if profile_access ->> 'status' is distinct from 'visible' then
        return jsonb_build_object('access', profile_access, 'shops', '[]'::jsonb);
    end if;

    select coalesce(jsonb_agg(page.shop order by page.created_at desc, page.shop_id desc), '[]'::jsonb)
    into saved_shops
    from (
        select jsonb_build_object(
                   'id', shop.id,
                   'name', shop.name,
                   'address', shop.address,
                   'lat', shop.lat,
                   'lng', shop.lng,
                   'kakao_place_url', shop.kakao_place_url,
                   'naver_place_url', shop.naver_place_url,
                   'instagram_url', shop.instagram_url,
                   'instagram_profile_image_path', shop.instagram_profile_image_path,
                   'menu_category_ids', shop.menu_category_ids,
                   'created_at', shop.created_at,
                   'updated_at', shop.updated_at
               ) as shop,
               bookmark.created_at, bookmark.shop_id
        from public.user_shop_bookmarks bookmark
        join public.ramen_shops shop on shop.id = bookmark.shop_id
        where bookmark.user_id = p_user_id and shop.is_visible
        order by bookmark.created_at desc, bookmark.shop_id desc
        limit 20 offset p_offset
    ) page;

    return jsonb_build_object('access', profile_access, 'shops', saved_shops);
end;
$$;

create or replace function public.fetch_profile_saved_shops(
    p_user_id uuid,
    p_offset bigint default 0
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
    select community_private.fetch_profile_saved_shops(p_user_id, p_offset);
$$;

revoke all on function community_private.fetch_profile_saved_shops(uuid, bigint) from public, anon;
revoke all on function public.fetch_profile_saved_shops(uuid, bigint) from public, anon;
grant execute on function community_private.fetch_profile_saved_shops(uuid, bigint) to authenticated;
grant execute on function public.fetch_profile_saved_shops(uuid, bigint) to authenticated;

commit;
