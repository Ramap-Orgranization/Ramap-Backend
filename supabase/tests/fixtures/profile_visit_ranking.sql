create role anon;
create role authenticated;
create role service_role;
alter default privileges grant execute on functions to anon, authenticated, service_role;

create schema auth;
create schema account_profile_private;
create schema community_private;
create schema storage;
create table auth.users(id uuid primary key);
create table account_profile_private.profile_daily_change_counts(
    user_id uuid,
    change_date date,
    nickname_changes integer,
    bio_changes integer
);
create table storage.objects(bucket_id text, name text);
create table public.account_deletion_requests(user_id uuid primary key);
create table public.public_profiles(
    user_id uuid primary key references auth.users(id),
    nickname text not null,
    bio text,
    avatar_path text,
    is_public boolean not null,
    suspended_at timestamptz
);
create table public.user_blocks(
    blocker_id uuid not null,
    blocked_id uuid not null,
    primary key (blocker_id, blocked_id)
);
create table public.ramen_shops(
    id uuid primary key,
    name text not null,
    is_visible boolean not null,
    instagram_profile_image_path text
);
create table public.user_shop_bookmarks(user_id uuid, shop_id uuid);
create table public.shop_reviews(
    id uuid primary key default gen_random_uuid(),
    user_id uuid references public.public_profiles(user_id),
    shop_id uuid not null references public.ramen_shops(id),
    is_public boolean not null,
    moderation_status text not null,
    image_paths text[] not null default '{}'
);

create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create function community_private.has_live_user() returns boolean language sql stable as $$
    select exists (select 1 from auth.users where id = auth.uid())
        and not exists (select 1 from public.account_deletion_requests where user_id = auth.uid());
$$;

create function community_private.fetch_blocked_profile(p_user_id uuid) returns jsonb language sql stable as $$
    select jsonb_build_object('user_id', p.user_id, 'nickname', p.nickname)
    from public.public_profiles p
    join public.user_blocks b on b.blocked_id = p.user_id
    where p.user_id = p_user_id and b.blocker_id = auth.uid();
$$;

create function community_private.can_view_blocked_review_once(uuid) returns boolean language sql stable as $$
    select false;
$$;

\ir ../../migrations/20260930155306_show_public_review_profiles_to_blocked_viewers.sql

-- This isolated fixture skips the intermediate review RPC replacement that added OUT columns.
drop function public.fetch_profile_reviews(uuid, bigint);
