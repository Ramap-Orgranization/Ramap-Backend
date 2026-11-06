begin;

alter table public.public_profiles
    add column followers_can_read_reviews boolean not null default true,
    add column followers_can_read_saved_shops boolean not null default true;

create table public.profile_follows (
    follower_id uuid not null references public.public_profiles(user_id) on delete cascade,
    followed_id uuid not null references public.public_profiles(user_id) on delete cascade,
    status text not null check (status in ('pending', 'following')),
    created_at timestamptz not null default now(),
    primary key (follower_id, followed_id),
    check (follower_id <> followed_id)
);
create index profile_follows_followed_page on public.profile_follows
    (followed_id, status, created_at desc, follower_id desc);
create index profile_follows_follower_page on public.profile_follows
    (follower_id, status, created_at desc, followed_id desc);
alter table public.profile_follows enable row level security;
revoke all on public.profile_follows from public, anon, authenticated;

-- All relation and block mutations lock the same identities in UUID order.
create function community_private.lock_follow_pair(p_first uuid, p_second uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
    perform 1 from public.public_profiles
    where user_id in (p_first, p_second) order by user_id for update;
end;
$$;
revoke all on function community_private.lock_follow_pair(uuid, uuid) from public, anon, authenticated;

create function community_private.can_read_follow_content(p_user_id uuid, p_content text)
returns boolean language sql stable security definer set search_path = '' as $$
    select exists (
        select 1 from public.public_profiles p
        where p.user_id = p_user_id and p.suspended_at is null
          and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id)
          and (
              p.user_id = auth.uid()
              or (
                  community_private.has_live_user()
                  and exists (select 1 from public.profile_follows f
                      where f.follower_id = auth.uid() and f.followed_id = p.user_id
                        and f.status = 'following')
                  and not exists (select 1 from public.user_blocks b
                      where (b.blocker_id = auth.uid() and b.blocked_id = p.user_id)
                         or (b.blocker_id = p.user_id and b.blocked_id = auth.uid()))
                  and case p_content
                      when 'reviews' then p.followers_can_read_reviews
                      when 'saved_shops' then p.followers_can_read_saved_shops
                      else false end
              )
          )
    );
$$;
revoke all on function community_private.can_read_follow_content(uuid, text) from public, anon, authenticated;

create function public.change_profile_follow(p_user_id uuid, p_action text)
returns void language plpgsql security definer set search_path = '' as $$
declare current_user_id uuid;
declare target public.public_profiles;
begin
    current_user_id := community_private.require_live_user();
    if p_user_id is null or p_user_id = current_user_id or p_action is null
       or p_action not in ('follow', 'unfollow', 'approve', 'reject', 'remove') then
        raise exception 'Invalid follow action' using errcode = '22023';
    end if;
    perform community_private.lock_follow_pair(current_user_id, p_user_id);
    perform account_profile_private.fetch_or_create_my_profile(current_user_id);
    if p_action = 'unfollow' then
        delete from public.profile_follows where follower_id = current_user_id and followed_id = p_user_id;
        return;
    end if;
    if p_action in ('reject', 'remove') then
        delete from public.profile_follows where follower_id = p_user_id and followed_id = current_user_id
          and status = case when p_action = 'reject' then 'pending' else 'following' end;
        return;
    end if;
    select * into target from public.public_profiles where user_id = p_user_id;
    if not found or target.suspended_at is not null
       or exists (select 1 from public.public_profiles where user_id = current_user_id and suspended_at is not null)
       or exists (select 1 from public.account_deletion_requests where user_id = p_user_id)
       or exists (select 1 from public.user_blocks
           where (blocker_id = current_user_id and blocked_id = p_user_id)
              or (blocker_id = p_user_id and blocked_id = current_user_id)) then
        raise exception 'Profile unavailable' using errcode = '42501';
    end if;
    if p_action = 'approve' then
        update public.profile_follows set status = 'following'
        where follower_id = p_user_id and followed_id = current_user_id and status = 'pending';
        return;
    end if;
    insert into public.profile_follows(follower_id, followed_id, status)
    values (current_user_id, p_user_id, case when target.is_public then 'following' else 'pending' end)
    on conflict (follower_id, followed_id) do nothing;
end;
$$;
revoke all on function public.change_profile_follow(uuid, text) from public, anon;
grant execute on function public.change_profile_follow(uuid, text) to authenticated;

create function public.fetch_my_follow_connections(p_list text, p_offset bigint default 0)
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
        select jsonb_build_object('user_id', p.user_id, 'nickname', p.nickname) as profile,
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
revoke all on function public.fetch_my_follow_connections(text, bigint) from public, anon;
grant execute on function public.fetch_my_follow_connections(text, bigint) to authenticated;

create function public.update_my_profile_visibility_v2(
    p_is_public boolean,
    p_followers_can_read_reviews boolean,
    p_followers_can_read_saved_shops boolean
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare owner_user_id uuid;
begin
    owner_user_id := community_private.require_live_user();
    if p_is_public is null or p_followers_can_read_reviews is null or p_followers_can_read_saved_shops is null then
        raise exception 'Invalid profile visibility' using errcode = '22023';
    end if;
    perform account_profile_private.fetch_or_create_my_profile(owner_user_id);
    if exists (select 1 from public.public_profiles where user_id = owner_user_id and suspended_at is not null) then
        raise exception 'Account is suspended' using errcode = '42501';
    end if;
    update public.public_profiles set is_public = p_is_public,
        followers_can_read_reviews = p_followers_can_read_reviews,
        followers_can_read_saved_shops = p_followers_can_read_saved_shops
    where user_id = owner_user_id;
    return account_profile_private.fetch_or_create_my_profile(owner_user_id);
end;
$$;
revoke all on function public.update_my_profile_visibility_v2(boolean, boolean, boolean) from public, anon;
grant execute on function public.update_my_profile_visibility_v2(boolean, boolean, boolean) to authenticated;

CREATE OR REPLACE FUNCTION account_profile_private.fetch_or_create_my_profile(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare profile public.public_profiles;
declare today date := account_profile_private.kst_profile_change_date(current_timestamp);
declare changes account_profile_private.profile_daily_change_counts;
begin
    if auth.uid() is null or p_user_id is distinct from auth.uid() then
        raise exception 'Authentication required or mismatched profile owner' using errcode = '42501';
    end if;
    select * into profile from public.public_profiles where user_id = p_user_id for update;
    if not found then
        begin
            insert into public.public_profiles(user_id, nickname, accepted_at)
            values (p_user_id, (array['설레는','느긋한','행복한','산책하는','든든한','수줍은','춤추는','반가운','호기심많은','여행하는','노래하는','꿈꾸는'])[1 + floor(random() * 12)::int]
                || (array['차슈','아지타마','멘마','돈코츠','쇼유라멘','시오라멘','미소라멘','츠케멘','탄탄멘','라멘한그릇','면발','나루토'])[1 + floor(random() * 12)::int], null)
            on conflict (user_id) do nothing;
        exception when unique_violation then
            -- A generated nickname can collide with a user-selected nickname.
        end;
        select * into profile from public.public_profiles where user_id = p_user_id for update;
    end if;
    while not found loop
        begin
            insert into public.public_profiles(user_id, nickname, accepted_at)
            values (p_user_id, '라멘' || nextval('account_profile_private.generated_nickname_number'::regclass)::text, null)
            on conflict (user_id) do nothing;
        exception when unique_violation then
            -- Advance the fallback sequence when a selected nickname used this value.
        end;
        select * into profile from public.public_profiles where user_id = p_user_id for update;
    end loop;
    select * into changes
    from account_profile_private.profile_daily_change_counts
    where user_id = p_user_id and change_date = today;
    return jsonb_build_object(
        'user_id', profile.user_id,
        'nickname', profile.nickname,
        'avatar_path', profile.avatar_path,
        'bio', profile.bio,
        'instagram_username', profile.instagram_username,
        'is_public', profile.is_public,
        'followers_can_read_reviews', profile.followers_can_read_reviews,
        'followers_can_read_saved_shops', profile.followers_can_read_saved_shops,
        'nickname_changes_remaining', 2 - coalesce(changes.nickname_changes, 0),
        'bio_changes_remaining', 2 - coalesce(changes.bio_changes, 0)
    );
end;
$function$;


create or replace function community_private.fetch_profile_access(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare profile jsonb;
declare blocked_profile jsonb;
declare public_access boolean;
declare follow_status text;
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
    return jsonb_build_object('status', 'visible', 'profile', profile,
        'follow_state', coalesce(follow_status, 'none'),
        'can_read_reviews', public_access or community_private.can_read_follow_content(p_user_id, 'reviews'),
        'can_read_saved_shops', public_access or community_private.can_read_follow_content(p_user_id, 'saved_shops'));
end;
$$;

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
           (
               select count(*)::integer
               from public.shop_reviews r_v
               where r_v.user_id = r.user_id
                 and r_v.shop_id = r.shop_id
                 and (
                     r_v.created_at < r.created_at
                     or (r_v.created_at = r.created_at and r_v.id <= r.id)
                 )
                 and r_v.is_public
                 and r_v.moderation_status = 'published'
           ) as visit_number
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
    if profile_access ->> 'status' is distinct from 'visible'
       or not coalesce((profile_access ->> 'can_read_saved_shops')::boolean, false) then
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


CREATE OR REPLACE FUNCTION community_private.can_read_review_image(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
              public.fetch_public_community_profile(r.user_id) is not null
              or community_private.can_view_blocked_review_once(r.id)
              or community_private.can_read_follow_content(r.user_id, 'reviews')
          )
    );
$function$;

CREATE OR REPLACE FUNCTION public.change_community_block(p_user_id uuid, p_blocked boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
begin
    current_user_id := community_private.require_live_user();
    if p_user_id is null or p_blocked is null or p_user_id = current_user_id then
        raise exception 'Invalid block';
    end if;
    perform community_private.lock_follow_pair(current_user_id, p_user_id);
    if p_blocked then
        if not exists (
            select 1 from public.public_profiles
            where user_id = p_user_id and suspended_at is null
        ) then
            raise exception 'Unknown community profile';
        end if;
        insert into public.user_blocks(blocker_id, blocked_id) values (current_user_id, p_user_id)
        on conflict (blocker_id, blocked_id) do nothing;
        delete from public.profile_follows
        where (follower_id = current_user_id and followed_id = p_user_id)
           or (follower_id = p_user_id and followed_id = current_user_id);
    else
        delete from public.user_blocks where blocker_id = current_user_id and blocked_id = p_user_id;
    end if;
end;
$function$;


create function public.fetch_profile_reviews_page_v2(p_user_id uuid, p_offset bigint default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare profile_access jsonb;
declare reviews jsonb;
begin
    if p_user_id is null or p_offset is null or p_offset < 0 then
        raise exception 'Invalid profile page' using errcode = '22023';
    end if;
    profile_access := community_private.fetch_profile_access(p_user_id);
    if profile_access ->> 'status' is distinct from 'visible'
       or not coalesce((profile_access ->> 'can_read_reviews')::boolean, false) then
        return jsonb_build_object('access', profile_access, 'reviews', '[]'::jsonb);
    end if;
    select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id desc), '[]'::jsonb)
    into reviews from public.fetch_profile_reviews(p_user_id, p_offset) r;
    return jsonb_build_object('access', profile_access, 'reviews', reviews);
end;
$$;
revoke all on function public.fetch_profile_reviews_page_v2(uuid, bigint) from public;
grant execute on function public.fetch_profile_reviews_page_v2(uuid, bigint) to anon, authenticated;

-- The request header may sign only the current avatar of an available, unblocked identity.
create function community_private.can_read_follow_header_avatar(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
    select exists (select 1 from public.public_profiles p
        where p.avatar_path = p_path and p.suspended_at is null
          and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id)
          and not exists (select 1 from public.user_blocks b
              where (b.blocker_id = auth.uid() and b.blocked_id = p.user_id)
                 or (b.blocker_id = p.user_id and b.blocked_id = auth.uid())));
$$;
revoke all on function community_private.can_read_follow_header_avatar(text) from public;
grant execute on function community_private.can_read_follow_header_avatar(text) to anon, authenticated;
create policy follow_header_avatar_read on storage.objects for select to anon, authenticated
using (bucket_id = 'profile-avatars' and community_private.can_read_follow_header_avatar(name));

commit;
