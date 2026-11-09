-- Minimal legacy contract, not a production schema dump.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
grant usage on schema auth to anon,authenticated,service_role;
grant execute on function auth.uid() to anon,authenticated,service_role;
create table public.ramen_shops(id uuid primary key,is_visible boolean not null default true);
alter table public.ramen_shops enable row level security;
grant select on public.ramen_shops to authenticated;
create policy visible_shops on public.ramen_shops for select to authenticated using (is_visible);
create table public.shop_event_notification_subscriptions (
    user_id uuid references auth.users(id) on delete cascade,
    shop_id uuid references public.ramen_shops(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key(user_id,shop_id)
);
alter table public.shop_event_notification_subscriptions enable row level security;
grant select,insert,delete on public.shop_event_notification_subscriptions to authenticated;
create policy own_events on public.shop_event_notification_subscriptions for all to authenticated
using (auth.uid()=user_id) with check (auth.uid()=user_id);
create table public.event_reminders(user_id uuid,event_id uuid,primary key(user_id,event_id));
insert into auth.users values ('00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000002');
insert into public.ramen_shops values ('10000000-0000-0000-0000-000000000001',true),('10000000-0000-0000-0000-000000000002',false);
insert into public.shop_event_notification_subscriptions(user_id,shop_id) values ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
insert into public.event_reminders values ('00000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001');
