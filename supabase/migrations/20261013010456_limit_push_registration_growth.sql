create schema push_registration_private;
revoke all on schema push_registration_private from public, anon, authenticated;
grant usage on schema push_registration_private to service_role;
create table push_registration_private.settings (
    singleton boolean primary key default true check (singleton),
    maximum_registrations integer not null default 5 check (maximum_registrations between 1 and 1000),
    actor_minute_limit integer not null default 5 check (actor_minute_limit between 1 and 10000),
    actor_daily_limit integer not null default 20 check (actor_daily_limit between 1 and 100000),
    refresh_window_seconds integer not null default 300 check (refresh_window_seconds between 1 and 3600),
    enabled boolean not null default true,
    digest_secret bytea not null default extensions.gen_random_bytes(32) check (octet_length(digest_secret) = 32)
);
create table push_registration_private.counters (
    actor_key text not null check (actor_key ~ '^[a-f0-9]{64}$'),
    scope text not null check (scope in ('minute', 'day')),
    window_start timestamptz not null,
    expires_at timestamptz not null,
    consumed integer not null check (consumed > 0),
    primary key (actor_key, scope, window_start)
);
create index push_registration_counters_expiry on push_registration_private.counters(expires_at);
alter table push_registration_private.settings enable row level security;
alter table push_registration_private.counters enable row level security;
revoke all on all tables in schema push_registration_private from public, anon, authenticated, service_role;
grant select (singleton, maximum_registrations, actor_minute_limit, actor_daily_limit, refresh_window_seconds, enabled)
    on push_registration_private.settings to service_role;
grant select on push_registration_private.counters to service_role;
insert into push_registration_private.settings(singleton) values (true);

create function push_registration_private.register_identifier(identifier text, platform text, target_type text)
returns void language plpgsql security definer set search_path = ''
as $function$
declare
    owner_id uuid;
    policy push_registration_private.settings%rowtype;
    existing_registration public.push_registrations%rowtype;
    actor_digest text;
    current_time_utc timestamptz;
    starts timestamptz[];
    expiries timestamptz[];
    scopes text[] := array['minute', 'day'];
    maxima integer[];
    used_slots bigint;
    consumed_units integer;
    retry_seconds integer := 0;
    index integer;
begin
    owner_id := community_private.require_live_user();
    if platform is null or platform not in ('android', 'ios')
        or target_type is null or target_type not in ('fid', 'token')
        or identifier is null or octet_length(identifier) > 2048
        or (target_type = 'fid' and identifier !~ '^[cdef][A-Za-z0-9_-]{21}$')
        or (target_type = 'token' and (char_length(identifier) < 20 or identifier ~ '[[:space:][:cntrl:]]')) then
        raise exception 'invalid push registration' using errcode = '22023';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.push-account.' || owner_id::text, 0));
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.push-identifier.' || identifier, 0));
    select * into policy from push_registration_private.settings where singleton for share;
    if not found or not policy.enabled then
        raise sqlstate 'PGRST'
            using message = '{"code":"PUSH_REGISTRATION_UNAVAILABLE","message":"Push registration temporarily unavailable"}',
                detail = '{"status":503,"headers":{"Retry-After":"30","Cache-Control":"no-store"}}';
    end if;
    current_time_utc := pg_catalog.clock_timestamp();
    select p.* into existing_registration from public.push_registrations p where p.identifier = register_identifier.identifier for update;
    if existing_registration.user_id = owner_id and existing_registration.platform = platform and existing_registration.target_type = target_type then
        if existing_registration.updated_at <= current_time_utc - pg_catalog.make_interval(secs => policy.refresh_window_seconds) then
            update public.push_registrations p set updated_at = current_time_utc
            where p.identifier = register_identifier.identifier and p.user_id = owner_id;
        end if;
        return;
    end if;
    if existing_registration.user_id is distinct from owner_id then
        select count(*) into used_slots from (
            select 1 from public.push_registrations p where p.user_id = owner_id limit policy.maximum_registrations
        ) slots;
        if used_slots >= policy.maximum_registrations then
            raise sqlstate 'PGRST'
                using message = '{"code":"PUSH_DEVICE_LIMIT_REACHED","message":"Push registration count limit reached"}',
                    detail = '{"status":409,"headers":{"Cache-Control":"no-store"}}';
        end if;
    end if;
    actor_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to('user:' || owner_id::text, 'UTF8'), policy.digest_secret, 'sha256'), 'hex');
    starts := array[pg_catalog.date_trunc('minute', current_time_utc), pg_catalog.date_trunc('day', current_time_utc at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'];
    expiries := array[starts[1] + interval '1 minute', starts[2] + interval '1 day'];
    maxima := array[policy.actor_minute_limit, policy.actor_daily_limit];
    for index in 1..2 loop
        select consumed into consumed_units from push_registration_private.counters
        where actor_key = actor_digest and scope = scopes[index] and window_start = starts[index];
        if coalesce(consumed_units, 0) >= maxima[index] then
            retry_seconds := greatest(retry_seconds, pg_catalog.ceil(extract(epoch from expiries[index] - current_time_utc))::integer);
        end if;
    end loop;
    if retry_seconds > 0 then
        raise sqlstate 'PGRST'
            using message = '{"code":"PUSH_REGISTRATION_RATE_LIMITED","message":"Push registration change limit reached"}',
                detail = pg_catalog.jsonb_build_object('status', 429, 'headers', pg_catalog.jsonb_build_object('Retry-After', retry_seconds::text, 'Cache-Control', 'no-store'))::text;
    end if;
    for index in 1..2 loop
        insert into push_registration_private.counters as counter (actor_key, scope, window_start, expires_at, consumed)
        values (actor_digest, scopes[index], starts[index], expiries[index], 1)
        on conflict (actor_key, scope, window_start) do update set consumed = counter.consumed + 1;
    end loop;
    insert into public.push_registrations as registration (identifier, user_id, platform, target_type, updated_at)
    values (register_identifier.identifier, owner_id, platform, target_type, current_time_utc)
    on conflict on constraint push_registrations_pkey do update set user_id = excluded.user_id, platform = excluded.platform,
        target_type = excluded.target_type, updated_at = excluded.updated_at;
    delete from push_registration_private.counters where ctid in (
        select ctid from push_registration_private.counters where expires_at < current_time_utc order by expires_at limit 32
    );
end;
$function$;
revoke all on all functions in schema push_registration_private from public, anon, authenticated, service_role;
comment on schema push_registration_private is 'Server-only push registration limits and keyed account counters; no raw user UUID, push identifier, token or IP retained.';

CREATE OR REPLACE FUNCTION public.register_push_registration(registration_identifier text, device_platform text, registration_target_type text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
    perform push_registration_private.register_identifier(registration_identifier, device_platform, registration_target_type);
end;
$function$;
