begin;

create or replace function community_private.fetch_profile_access(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare profile jsonb;
declare blocked_profile jsonb;
declare public_access boolean;
declare follow_status text;
declare reviews_access boolean;
declare saved_shops_access boolean;
declare followers bigint;
declare following bigint;
declare reviews bigint;
declare saved_shops bigint;
begin
    if p_user_id is null then return jsonb_build_object('status', 'unavailable'); end if;
    if auth.uid() is not null then
        blocked_profile := community_private.fetch_blocked_profile(p_user_id);
        if blocked_profile is not null then
            return jsonb_build_object('status', 'blocked', 'profile', blocked_profile);
        end if;
    end if;
    public_access := public.fetch_public_community_profile(p_user_id) is not null;
    select jsonb_build_object('user_id', p.user_id, 'nickname', p.nickname,
        'avatar_path', p.avatar_path, 'bio', case when public_access then p.bio else '' end)
    into profile from public.public_profiles p
    where p.user_id = p_user_id and p.suspended_at is null
      and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id)
      and (public_access or not exists (select 1 from public.user_blocks b
          where b.blocker_id = p.user_id and b.blocked_id = auth.uid()));
    if profile is null then return jsonb_build_object('status', 'unavailable'); end if;
    select f.status into follow_status from public.profile_follows f
    where f.follower_id = auth.uid() and f.followed_id = p_user_id;
    reviews_access := public_access or community_private.can_read_follow_content(p_user_id, 'reviews');
    saved_shops_access := public_access or community_private.can_read_follow_content(p_user_id, 'saved_shops');

    -- Count approved relationships only, excluding unavailable accounts.
    select count(*) into followers
    from public.profile_follows f
    join public.public_profiles p on p.user_id = f.follower_id
    where f.followed_id = p_user_id and f.status = 'following'
      and p.suspended_at is null
      and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id);

    select count(*) into following
    from public.profile_follows f
    join public.public_profiles p on p.user_id = f.followed_id
    where f.follower_id = p_user_id and f.status = 'following'
      and p.suspended_at is null
      and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id);

    -- Match the visibility rules of the paged content endpoints.
    -- A null count means the viewer is not allowed to read that content.
    if reviews_access then
        select count(*) into reviews from public.shop_reviews r
        where r.user_id = p_user_id
          and (p_user_id = auth.uid() or (r.is_public and r.moderation_status = 'published'));
    end if;
    if saved_shops_access and auth.uid() is not null then
        select count(*) into saved_shops
        from public.user_shop_bookmarks b
        join public.ramen_shops s on s.id = b.shop_id
        where b.user_id = p_user_id and s.is_visible;
    end if;

    return jsonb_build_object('status', 'visible', 'profile', profile,
        'follow_state', coalesce(follow_status, 'none'),
        'can_read_reviews', reviews_access,
        'can_read_saved_shops', saved_shops_access,
        'follower_count', followers,
        'following_count', following,
        'review_count', reviews,
        'saved_shop_count', saved_shops);
end;
$$;

create or replace function public.fetch_my_follow_connections(p_list text, p_offset bigint default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare current_user_id uuid;
declare result jsonb;
begin
    current_user_id := community_private.require_live_user();
    if p_list is null or p_list not in ('followers', 'following', 'requests')
       or p_offset is null or p_offset < 0 then
        raise exception 'Invalid follow page' using errcode = '22023';
    end if;
    select coalesce(jsonb_agg(page.profile order by page.created_at desc, page.user_id desc), '[]'::jsonb)
    into result from (
        select jsonb_build_object('user_id', p.user_id, 'nickname', p.nickname, 'avatar_path', p.avatar_path) as profile,
               f.created_at, p.user_id
        from public.profile_follows f join public.public_profiles p
          on p.user_id = case when p_list = 'following' then f.followed_id else f.follower_id end
        where (case when p_list = 'following' then f.follower_id else f.followed_id end) = current_user_id
          and f.status = case when p_list = 'requests' then 'pending' else 'following' end
          and p.suspended_at is null
          and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id)
          and not exists (select 1 from public.user_blocks b
              where (b.blocker_id = current_user_id and b.blocked_id = p.user_id)
                 or (b.blocker_id = p.user_id and b.blocked_id = current_user_id))
        order by f.created_at desc, p.user_id desc limit 20 offset p_offset
    ) page;
    return result;
end;
$$;

commit;
