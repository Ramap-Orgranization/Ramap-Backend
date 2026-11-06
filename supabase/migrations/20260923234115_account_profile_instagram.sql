-- Optional Instagram profile link. Omitted/null values preserve legacy client data.
alter table public.public_profiles
    add column instagram_username text not null default '',
    add constraint public_profiles_instagram_username_valid check (
        instagram_username = '' or (
            char_length(instagram_username) <= 30
            and instagram_username ~ '^[a-z0-9_]+(\.[a-z0-9_]+)*$'
            and instagram_username not in ('about', 'accounts', 'api', 'challenge', 'developer', 'developers', 'direct', 'emails', 'explore', 'legal', 'nametag', 'oauth', 'p', 'privacy', 'reel', 'reels', 'share', 'stories', 'terms', 'tv', 'web')
        )
    );

create or replace function account_profile_private.guard_profile_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
    if tg_op = 'UPDATE' and (new.nickname is distinct from old.nickname
        or new.avatar_path is distinct from old.avatar_path
        or new.bio is distinct from old.bio
        or new.instagram_username is distinct from old.instagram_username) then
        new.approved_at := null;
    end if;
    return new;
end;
$$;

create or replace function account_profile_private.fetch_or_create_my_profile(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare profile public.public_profiles;
begin
    if auth.uid() is null or p_user_id is distinct from auth.uid() then
        raise exception 'Authentication required or mismatched profile owner' using errcode = '42501';
    end if;
    insert into public.public_profiles(user_id, nickname, accepted_at)
    values (p_user_id, (array['설레는','느긋한','행복한','산책하는','든든한','수줍은','춤추는','반가운','호기심많은','여행하는','노래하는','꿈꾸는'])[1 + floor(random() * 12)::int]
        || (array['차슈','아지타마','멘마','돈코츠','쇼유라멘','시오라멘','미소라멘','츠케멘','탄탄멘','라멘한그릇','면발','나루토'])[1 + floor(random() * 12)::int], null)
    on conflict (user_id) do nothing;
    select * into strict profile from public.public_profiles where user_id = p_user_id for update;
    return jsonb_build_object('user_id', profile.user_id, 'nickname', profile.nickname, 'avatar_path', profile.avatar_path, 'bio', profile.bio, 'instagram_username', profile.instagram_username);
end;
$$;
revoke all on function account_profile_private.fetch_or_create_my_profile(uuid) from public, anon, authenticated;
grant execute on function account_profile_private.fetch_or_create_my_profile(uuid) to authenticated;

-- Replace signatures instead of overloading: PostgREST must resolve one RPC.
drop function public.update_my_profile(uuid, text, text, boolean, text);
drop function account_profile_private.update_my_profile(uuid, text, text, boolean, text);

create function account_profile_private.update_my_profile(
    p_user_id uuid, p_nickname text, p_avatar_path text default null, p_remove_photo boolean default false, p_bio text default null, p_instagram_username text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare profile public.public_profiles;
begin
    if auth.uid() is null or p_user_id is distinct from auth.uid() then
        raise exception 'Authentication required or mismatched profile owner' using errcode = '42501';
    end if;
    if p_nickname is null or p_nickname !~ '^[A-Za-z0-9가-힣_]{2,10}$'
        or p_remove_photo is null or (p_remove_photo and p_avatar_path is not null) then
        raise exception 'Invalid profile update';
    end if;
    perform account_profile_private.fetch_or_create_my_profile(p_user_id);
    select * into strict profile from public.public_profiles where user_id = p_user_id for update;
    if profile.suspended_at is not null then raise exception 'Account is suspended' using errcode = '42501'; end if;
    if p_avatar_path is not null then
        if p_avatar_path !~ ('^' || p_user_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png)$')
            or not exists (select 1 from storage.objects where bucket_id = 'profile-avatars' and name = p_avatar_path)
        then raise exception 'Invalid profile avatar'; end if;
    end if;
    update public.public_profiles set nickname = p_nickname,
        bio = coalesce(p_bio, bio),
        instagram_username = coalesce(p_instagram_username, instagram_username),
        avatar_path = case when p_remove_photo then null else coalesce(p_avatar_path, avatar_path) end
    where user_id = p_user_id;
    return account_profile_private.fetch_or_create_my_profile(p_user_id);
end;
$$;
revoke all on function account_profile_private.update_my_profile(uuid, text, text, boolean, text, text) from public, anon, authenticated;
grant execute on function account_profile_private.update_my_profile(uuid, text, text, boolean, text, text) to authenticated;

create function public.update_my_profile(
    p_user_id uuid, p_nickname text, p_avatar_path text default null, p_remove_photo boolean default false, p_bio text default null, p_instagram_username text default null
)
returns jsonb language sql security invoker set search_path = '' as $$
    select account_profile_private.update_my_profile(p_user_id, p_nickname, p_avatar_path, p_remove_photo, p_bio, p_instagram_username);
$$;
revoke all on function public.update_my_profile(uuid, text, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public.update_my_profile(uuid, text, text, boolean, text, text) to authenticated;

