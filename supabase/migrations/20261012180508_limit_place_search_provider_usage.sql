create schema place_search_private;
revoke all on schema place_search_private from public, anon, authenticated;
grant usage on schema place_search_private to service_role;

create table place_search_private.budget_settings (
    kind text primary key check (kind in ('request', 'naver_local', 'naver_geocoding')),
    minute_limit integer not null check (minute_limit between 1 and 10000),
    daily_limit integer not null check (daily_limit between 1 and 100000),
    client_minute_limit integer not null default 20 check (client_minute_limit between 1 and 10000),
    client_hour_limit integer not null default 120 check (client_hour_limit between 1 and 100000),
    enabled boolean not null default true
);
create table place_search_private.budget_counters (
    kind text not null references place_search_private.budget_settings(kind),
    scope text not null check (scope in ('global_minute', 'global_day', 'client_minute', 'client_hour')),
    actor_key text not null check (actor_key = '' or actor_key ~ '^[a-f0-9]{64}$'),
    window_start timestamptz not null,
    expires_at timestamptz not null,
    consumed integer not null check (consumed > 0),
    primary key (kind, scope, actor_key, window_start)
);
create index budget_counters_expiry on place_search_private.budget_counters(expires_at);
alter table place_search_private.budget_settings enable row level security;
alter table place_search_private.budget_counters enable row level security;
revoke all on place_search_private.budget_settings, place_search_private.budget_counters from public, anon, authenticated;
grant select on place_search_private.budget_settings to service_role;
grant select, insert, update, delete on place_search_private.budget_counters to service_role;

insert into place_search_private.budget_settings (kind, minute_limit, daily_limit)
values ('request', 120, 2000), ('naver_local', 100, 1000), ('naver_geocoding', 20, 200);

-- Only the server may reserve units. A transaction lock serializes each kind;
-- no lock is held during a provider HTTP call. Every network attempt costs one.
create function public.consume_place_search_budget(p_kind text, p_actor_key text default null)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $function$
declare
    limits place_search_private.budget_settings%rowtype;
    current_time_utc timestamptz;
    minute_start timestamptz;
    day_start timestamptz;
    hour_start timestamptz;
    scopes text[];
    actors text[];
    starts timestamptz[];
    expiries timestamptz[];
    maxima integer[];
    used integer;
    retry_seconds integer := 0;
    blocked_scope text := 'client';
    index integer;
begin
    if p_kind is null or p_kind not in ('request', 'naver_local', 'naver_geocoding') then
        raise exception 'invalid budget kind' using errcode = '22023';
    end if;
    if p_kind = 'request' and (p_actor_key is null or p_actor_key !~ '^[a-f0-9]{64}$') then
        raise exception 'invalid budget actor' using errcode = '22023';
    end if;

    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.place-search.' || p_kind, 0));
    select * into limits from place_search_private.budget_settings where kind = p_kind;
    if not found or not limits.enabled then
        return pg_catalog.jsonb_build_object('allowed', false, 'reason', 'disabled', 'scope', 'global', 'retry_after_seconds', 30);
    end if;

    current_time_utc := pg_catalog.clock_timestamp();
    minute_start := pg_catalog.date_trunc('minute', current_time_utc);
    hour_start := pg_catalog.date_trunc('hour', current_time_utc);
    day_start := pg_catalog.date_trunc('day', current_time_utc at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
    scopes := array['global_minute', 'global_day'];
    actors := array['', ''];
    starts := array[minute_start, day_start];
    expiries := array[minute_start + interval '1 minute', day_start + interval '1 day'];
    maxima := array[limits.minute_limit, limits.daily_limit];
    if p_kind = 'request' then
        scopes := scopes || array['client_minute', 'client_hour'];
        actors := actors || array[p_actor_key, p_actor_key];
        starts := starts || array[minute_start, hour_start];
        expiries := expiries || array[minute_start + interval '1 minute', hour_start + interval '1 hour'];
        maxima := maxima || array[limits.client_minute_limit, limits.client_hour_limit];
    end if;

    for index in 1..pg_catalog.array_length(scopes, 1) loop
        select consumed into used from place_search_private.budget_counters
        where kind = p_kind and scope = scopes[index] and actor_key = actors[index] and window_start = starts[index];
        if coalesce(used, 0) >= maxima[index] then
            retry_seconds := greatest(retry_seconds, pg_catalog.ceil(extract(epoch from expiries[index] - current_time_utc))::integer);
            if actors[index] = '' then blocked_scope := 'global'; end if;
        end if;
    end loop;
    if retry_seconds > 0 then
        return pg_catalog.jsonb_build_object('allowed', false, 'reason', 'limit', 'scope', blocked_scope, 'retry_after_seconds', retry_seconds);
    end if;

    for index in 1..pg_catalog.array_length(scopes, 1) loop
        insert into place_search_private.budget_counters as counter (kind, scope, actor_key, window_start, expires_at, consumed)
        values (p_kind, scopes[index], actors[index], starts[index], expiries[index], 1)
        on conflict (kind, scope, actor_key, window_start)
        do update set consumed = counter.consumed + 1;
    end loop;
    -- Bounded opportunistic cleanup. Rejected requests never write counters.
    delete from place_search_private.budget_counters where ctid in (
        select ctid from place_search_private.budget_counters
        where expires_at < current_time_utc order by expires_at limit 32
    );
    return pg_catalog.jsonb_build_object('allowed', true);
end;
$function$;
revoke all on function public.consume_place_search_budget(text, text) from public, anon, authenticated;
grant execute on function public.consume_place_search_budget(text, text) to service_role;

comment on function public.consume_place_search_budget(text, text) is 'Server-only atomic request/provider budgets. Day windows reset at midnight Asia/Seoul. Clients cannot change or reset limits.';
