-- Minimal pre-catalog contracts only. No production data or credentials.
\ir shop_notification_settings.sql
create schema push_registration_private;
create table public.push_registrations(identifier text primary key,user_id uuid references auth.users(id),platform text not null,target_type text not null,updated_at timestamptz not null default now());
alter table public.push_registrations enable row level security;
create function push_registration_private.register_identifier(identifier text,platform text,target_type text) returns void language plpgsql security definer set search_path='' as $$
begin
    if auth.uid() is null then raise exception 'authentication_required'; end if;
    if platform not in ('android','ios') or target_type not in ('fid','token') or length(identifier)<20 then raise exception 'invalid push registration'; end if;
    insert into public.push_registrations values(identifier,auth.uid(),platform,target_type,now())
    on conflict on constraint push_registrations_pkey do update set user_id=excluded.user_id,platform=excluded.platform,target_type=excluded.target_type;
end;
$$;
create function public.register_push_registration(registration_identifier text,device_platform text,registration_target_type text) returns void language plpgsql security definer set search_path='' as $$
begin perform push_registration_private.register_identifier(registration_identifier,device_platform,registration_target_type); end;
$$;
create table public.shop_events(id uuid primary key,shop_id uuid references public.ramen_shops(id),title text,start_date date);
create table public.shop_event_participants(id uuid primary key default gen_random_uuid(),event_id uuid references public.shop_events(id),shop_id uuid references public.ramen_shops(id));
-- Match the hosted relation boundary: callers see views, linkage belongs only
-- to the canonical private table. Public planned_close is mapped and filtered.
create schema operating_notice_private;
create table operating_notice_private.shop_operating_notices(
    id uuid primary key default gen_random_uuid(),shop_id uuid not null references public.ramen_shops(id),
    raw_post_id uuid not null,notice_type text not null default 'operating_notice',description text,
    notice_date date not null,start_time time,end_time time,source_url text not null,
    ocr_text text,confidence numeric,review_note text,created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),end_date date,schedule_override jsonb,
    manually_released_at timestamptz,daily_schedules jsonb not null default '[]'::jsonb
);
create view public.admin_shop_operating_notice_records as
select id,shop_id,raw_post_id,notice_type,description,notice_date,start_time,end_time,source_url,
       ocr_text,confidence,review_note,created_at,updated_at,end_date,schedule_override,manually_released_at,daily_schedules
from operating_notice_private.shop_operating_notices;
create view public.shop_operating_notices as
select id,shop_id,case when notice_type='planned_close' then 'early_close' else notice_type end as notice_type,
       coalesce(description,'') as description,notice_date,start_time,end_time,source_url,created_at,updated_at,
       end_date,schedule_override,manually_released_at,daily_schedules,notice_type as notice_category
from operating_notice_private.shop_operating_notices
where notice_type='full_close' or notice_type in ('early_close','planned_close') and end_time is not null;
grant usage on schema operating_notice_private to service_role;
grant select,insert,update,delete on operating_notice_private.shop_operating_notices to service_role;
create table public.event_notification_deliveries(event_id uuid,user_id uuid,registration_identifier text,notification_type text,status text,attempt_count smallint not null default 1,last_error text,claimed_at timestamptz default now(),updated_at timestamptz default now(),sent_at timestamptz,primary key(event_id,user_id,registration_identifier,notification_type));
create table public.user_event_notification_preferences(user_id uuid primary key,enabled boolean not null);
grant all on all tables in schema public to service_role;
grant usage on schema auth to service_role;
grant execute on function auth.uid() to service_role;
