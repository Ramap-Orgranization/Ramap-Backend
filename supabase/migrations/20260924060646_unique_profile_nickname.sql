-- The index is the final arbiter even if two clients both pass availability checks.
create unique index public_profiles_nickname_lower_unique
    on public.public_profiles (lower(nickname));

create sequence account_profile_private.generated_nickname_number;
revoke all on sequence account_profile_private.generated_nickname_number from public, anon, authenticated;

create or replace function account_profile_private.fetch_or_create_my_profile(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare profile public.public_profiles;
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
            -- The natural nickname was taken; use the collision-safe fallback below.
        end;
        select * into profile from public.public_profiles where user_id = p_user_id for update;
    end if;
    while not found loop
        begin
            insert into public.public_profiles(user_id, nickname, accepted_at)
            values (p_user_id, '라멘' || nextval('account_profile_private.generated_nickname_number'::regclass)::text, null)
            on conflict (user_id) do nothing;
        exception when unique_violation then
            -- A member may already have chosen this generated name; advance the sequence.
        end;
        select * into profile from public.public_profiles where user_id = p_user_id for update;
    end loop;
    return jsonb_build_object('user_id', profile.user_id, 'nickname', profile.nickname, 'avatar_path', profile.avatar_path, 'bio', profile.bio, 'instagram_username', profile.instagram_username);
end;
$$;

create function account_profile_private.is_profile_nickname_available(p_nickname text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
    if auth.uid() is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if p_nickname is null or p_nickname !~ '^[A-Za-z0-9가-힣_]{2,10}$' then
        return false;
    end if;
    return not exists (
        select 1 from public.public_profiles
        where lower(nickname) = lower(p_nickname) and user_id <> auth.uid()
    );
end;
$$;
revoke all on function account_profile_private.is_profile_nickname_available(text) from public, anon, authenticated;
grant execute on function account_profile_private.is_profile_nickname_available(text) to authenticated;

create function public.is_profile_nickname_available(p_nickname text)
returns boolean language sql stable security invoker set search_path = '' as $$
    select account_profile_private.is_profile_nickname_available(p_nickname);
$$;
revoke all on function public.is_profile_nickname_available(text) from public, anon, authenticated;
grant execute on function public.is_profile_nickname_available(text) to authenticated;
