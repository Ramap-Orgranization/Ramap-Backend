-- Additional account and media dependencies for the review visit fixture.
create role service_role;
create schema media_private;
create schema storage;
create function auth.role() returns text language sql stable as $$
    select nullif(current_setting('request.jwt.claim.role', true), '');
$$;
create table auth.users(id uuid primary key);
alter table public.shop_reviews
    alter column user_id set not null,
    add constraint shop_reviews_user_id_fkey foreign key(user_id) references auth.users(id) on delete cascade,
    add constraint shop_reviews_image_paths_owner check (array_position(image_paths, null) is null);
alter table public.public_profiles
    add column bio text,
    add foreign key(user_id) references auth.users(id) on delete cascade;
alter table public.account_deletion_requests
    add foreign key(user_id) references auth.users(id) on delete cascade;
alter table public.review_likes add unique(review_id, user_id);
create table storage.objects(
    bucket_id text, name text, owner uuid, owner_id text,
    created_at timestamptz default now(), primary key(bucket_id, name)
);
create table media_private.objects(id uuid primary key, owner_id uuid, path text, state text);
create function media_private.queue_delete(p_id uuid) returns void language sql as $$
    update media_private.objects set state = 'deleting' where id = p_id;
$$;
create function public.shop_review_image_paths_belong_to_user(p_paths text[], p_user_id uuid)
returns boolean language sql immutable as $$
    select coalesce(bool_and(split_part(path, '/', 1) = p_user_id::text), true)
    from unnest(p_paths) path;
$$;
create function community_private.has_live_user() returns boolean language sql stable as $$
    select exists (select 1 from auth.users where id = auth.uid())
       and not exists (select 1 from public.account_deletion_requests where user_id = auth.uid());
$$;
create function community_private.can_view_public_profile(p_user_id uuid) returns boolean language sql stable as $$
    select exists (
        select 1 from public.public_profiles p
        where p.user_id = p_user_id and p.is_public and p.suspended_at is null
          and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id)
    );
$$;
create table public.community_reports(
    reporter_id uuid not null references auth.users(id) on delete cascade,
    target_user_id uuid not null references auth.users(id) on delete cascade,
    review_id uuid, target_type text not null,
    target_id uuid not null, reason text, details text, review_body_snapshot text, review_image_paths_snapshot text[],
    profile_nickname_snapshot text, profile_bio_snapshot text, profile_avatar_path_snapshot text,
    status text default 'pending', check (reporter_id <> target_user_id)
);
create unique index on public.community_reports(reporter_id, target_type, target_id) where status = 'pending';
