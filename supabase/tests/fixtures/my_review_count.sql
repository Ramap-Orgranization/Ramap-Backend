create role anon;
create role authenticated;
create schema auth;
create schema community_private;
create table auth.users(id uuid primary key);
create table public.account_deletion_requests(user_id uuid primary key);
create table public.shop_reviews(
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null,
    is_public boolean not null,
    moderation_status text not null
);
create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
create function community_private.require_live_user() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
    current_user_id uuid := auth.uid();
    locked_user_id uuid;
begin
    if current_user_id is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    select id into locked_user_id from auth.users where id = current_user_id for key share;
    if locked_user_id is null or exists(select 1 from public.account_deletion_requests where user_id = current_user_id) then
        raise exception 'Account is unavailable' using errcode = '42501';
    end if;
    return current_user_id;
end;
$$;

insert into auth.users(id) values
('00000000-0000-0000-0000-000000000001'),
('00000000-0000-0000-0000-000000000002'),
('00000000-0000-0000-0000-000000000003');
insert into public.shop_reviews(user_id,is_public,moderation_status) values
('00000000-0000-0000-0000-000000000001',true,'published'),
('00000000-0000-0000-0000-000000000001',false,'published'),
('00000000-0000-0000-0000-000000000001',true,'pending'),
('00000000-0000-0000-0000-000000000001',false,'rejected'),
('00000000-0000-0000-0000-000000000002',true,'published');
