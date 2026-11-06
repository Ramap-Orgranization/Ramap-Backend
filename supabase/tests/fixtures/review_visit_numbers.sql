-- Disposable empty PostgreSQL database only. Minimal dependencies for projection tests.
-- Run with supabase/tests/review_visit_numbers_test.py.
create role anon;
create role authenticated;
create schema auth;
create schema community_private;
create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
create function community_private.require_live_user() returns uuid language plpgsql as $$
begin
    if auth.uid() is null then raise exception 'Authentication required'; end if;
    return auth.uid();
end;
$$;
create table public.ramen_shops(
    id uuid primary key, name text, address text, lat numeric, lng numeric,
    kakao_place_url text, naver_place_url text, waiting_provider text, waiting_provider_url text,
    business_hours_weekly jsonb, business_hours_break_times jsonb, business_hours_last_orders jsonb,
    business_hours_notice text, business_hours_notice_type text, instagram_url text,
    instagram_profile_image_path text, menu_category_ids integer[], is_visible boolean default true,
    created_at timestamptz default now(), updated_at timestamptz default now()
);
create table public.public_profiles(user_id uuid primary key, nickname text, avatar_path text, is_public boolean, suspended_at timestamptz);
create table public.shop_reviews(
    id uuid primary key default gen_random_uuid(), shop_id uuid, user_id uuid, body text, created_at timestamptz default now(),
    image_paths text[] default '{}', moderation_status text default 'published',
    moderation_note text, is_public boolean default true, visit_number integer not null,
    unique (user_id, shop_id, visit_number)
);
create table community_private.review_visit_counters(
    user_id uuid, shop_id uuid, last_visit_number integer not null check (last_visit_number > 0),
    primary key (user_id, shop_id)
);
-- Mirror the deployed insert trigger: stored ordinals are never reused on deletion.
create function community_private.assign_review_visit_number() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    insert into community_private.review_visit_counters(user_id, shop_id, last_visit_number)
    values (new.user_id, new.shop_id, 1)
    on conflict (user_id, shop_id) do update
        set last_visit_number = community_private.review_visit_counters.last_visit_number + 1
    returning last_visit_number into new.visit_number;
    return new;
end;
$$;
create trigger assign_review_visit_number_before_insert before insert on public.shop_reviews
    for each row execute function community_private.assign_review_visit_number();
create table public.user_blocks(blocker_id uuid, blocked_id uuid);
create table public.account_deletion_requests(user_id uuid);
create table public.review_likes(review_id uuid, user_id uuid);
create table public.user_shop_bookmarks(user_id uuid, shop_id uuid);
create table public.profile_follows(follower_id uuid, followed_id uuid, status text);
create function public.fetch_public_community_profile(uuid) returns jsonb language sql stable as $$
    select to_jsonb(p) from public.public_profiles p where user_id=$1 and is_public;
$$;
create function community_private.can_read_follow_content(uuid,text) returns boolean language sql stable as $$ select false; $$;
create function community_private.can_view_blocked_review_once(p_review_id uuid) returns boolean
language sql stable as $$
    select exists (
        select 1 from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        join public.user_blocks b on b.blocker_id = auth.uid() and b.blocked_id = r.user_id
        where r.id = p_review_id and r.is_public and r.moderation_status = 'published' and p.is_public
    );
$$;
