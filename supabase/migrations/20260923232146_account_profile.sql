-- Standalone profile prerequisite; also applies after 20260906100000 in historical order.
-- The pending community migration also reuses this table when installed afterward.
create table if not exists public.public_profiles (
    user_id uuid primary key references auth.users(id) on delete cascade,
    nickname text not null check (nickname ~ '^[A-Za-z0-9가-힣_]{2,20}$'),
    accepted_guidelines_version text,
    accepted_at timestamptz,
    approved_at timestamptz,
    suspended_at timestamptz
);
alter table public.public_profiles
    alter column accepted_guidelines_version drop not null,
    alter column accepted_at drop not null,
    alter column accepted_at set default now(),
    add column if not exists avatar_path text;
alter table public.public_profiles enable row level security;
-- Limit even projects with permissive default table grants to existing public identity columns.
revoke all on public.public_profiles from public, anon, authenticated;
grant select (user_id, nickname) on public.public_profiles to anon, authenticated;

create schema if not exists account_profile_private;
revoke all on schema account_profile_private from public, anon, authenticated;
grant usage on schema account_profile_private to authenticated;

create function account_profile_private.guard_profile_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
    if tg_op = 'UPDATE' and (new.nickname is distinct from old.nickname
        or new.avatar_path is distinct from old.avatar_path) then
        new.approved_at := null;
    end if;
    return new;
end;
$$;
revoke all on function account_profile_private.guard_profile_identity() from public, anon, authenticated;
create trigger guard_profile_identity before update on public.public_profiles
for each row execute function account_profile_private.guard_profile_identity();

create function account_profile_private.fetch_or_create_my_profile(p_user_id uuid)
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
    return jsonb_build_object('user_id', profile.user_id, 'nickname', profile.nickname, 'avatar_path', profile.avatar_path);
end;
$$;
revoke all on function account_profile_private.fetch_or_create_my_profile(uuid) from public, anon, authenticated;
grant execute on function account_profile_private.fetch_or_create_my_profile(uuid) to authenticated;

create function public.fetch_or_create_my_profile(p_user_id uuid)
returns jsonb language sql security invoker set search_path = '' as $$
    select account_profile_private.fetch_or_create_my_profile(p_user_id);
$$;
revoke all on function public.fetch_or_create_my_profile(uuid) from public, anon, authenticated;
grant execute on function public.fetch_or_create_my_profile(uuid) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-avatars', 'profile-avatars', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create function account_profile_private.update_my_profile(
    p_user_id uuid, p_nickname text, p_avatar_path text default null, p_remove_photo boolean default false
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
        avatar_path = case when p_remove_photo then null else coalesce(p_avatar_path, avatar_path) end
    where user_id = p_user_id;
    return account_profile_private.fetch_or_create_my_profile(p_user_id);
end;
$$;
revoke all on function account_profile_private.update_my_profile(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function account_profile_private.update_my_profile(uuid, text, text, boolean) to authenticated;

create function public.update_my_profile(
    p_user_id uuid, p_nickname text, p_avatar_path text default null, p_remove_photo boolean default false
)
returns jsonb language sql security invoker set search_path = '' as $$
    select account_profile_private.update_my_profile(p_user_id, p_nickname, p_avatar_path, p_remove_photo);
$$;
revoke all on function public.update_my_profile(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.update_my_profile(uuid, text, text, boolean) to authenticated;

create function account_profile_private.can_delete_avatar(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
    select auth.uid() is not null and split_part(p_path, '/', 1) = auth.uid()::text
        and not exists (select 1 from public.public_profiles where avatar_path = p_path);
$$;
revoke all on function account_profile_private.can_delete_avatar(text) from public, anon, authenticated;
grant execute on function account_profile_private.can_delete_avatar(text) to authenticated;

create policy "Owners read profile avatars" on storage.objects for select to authenticated
using (bucket_id = 'profile-avatars' and split_part(name, '/', 1) = (select auth.uid())::text);
create policy "Owners upload new profile avatars" on storage.objects for insert to authenticated
with check (bucket_id = 'profile-avatars' and name ~ ('^' || (select auth.uid())::text
    || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png)$'));
-- Immutable UUID uploads: no UPDATE policy, and referenced photos cannot be deleted.
create policy "Owners delete unused profile avatars" on storage.objects for delete to authenticated
using (bucket_id = 'profile-avatars' and account_profile_private.can_delete_avatar(name));
