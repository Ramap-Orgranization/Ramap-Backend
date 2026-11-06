begin;

create table report_submission_private.place_validation_counters (
    scope text not null check (scope in ('global_minute', 'global_day', 'actor_minute', 'actor_day')),
    actor_key text not null check (actor_key = '' or actor_key ~ '^[a-f0-9]{64}$'),
    window_start timestamptz not null,
    expires_at timestamptz not null,
    consumed integer not null check (consumed > 0),
    primary key (scope, actor_key, window_start)
);
create index place_validation_counters_expiry on report_submission_private.place_validation_counters(expires_at);
alter table report_submission_private.place_validation_counters enable row level security;
revoke all on report_submission_private.place_validation_counters from public, anon, authenticated, service_role;

create function report_submission_private.require_place_report_actor(p_actor_uid uuid, p_actor_ip text)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
    if p_actor_uid is not null then
        if not exists (select 1 from auth.users u where u.id = p_actor_uid)
            or exists (select 1 from public.account_deletion_requests d where d.user_id = p_actor_uid) then
            raise exception 'report actor unavailable' using errcode = '42501';
        end if;
    elsif p_actor_ip is null or char_length(p_actor_ip) not between 1 and 64
        or (p_actor_ip <> 'shared-anonymous' and p_actor_ip !~ '^[0-9a-fA-F.:]+$') then
        raise exception 'invalid report actor' using errcode = '22023';
    end if;
end;
$function$;

-- Attempt limits commit before provider I/O, including failed validations.
create function public.reserve_place_report_validation(p_actor_uid uuid, p_actor_ip text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
    limits report_submission_private.submission_limits%rowtype;
    current_time_utc timestamptz;
    minute_start timestamptz;
    day_start timestamptz;
    actor_label text;
    actor_digest text;
    scopes text[] := array['global_minute', 'global_day', 'actor_minute', 'actor_day'];
    actors text[];
    starts timestamptz[];
    expiries timestamptz[];
    maxima integer[];
    consumed_units integer;
    retry_seconds integer := 0;
    index integer;
begin
    perform report_submission_private.require_place_report_actor(p_actor_uid, p_actor_ip);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.place-report-validation', 0));
    select * into limits from report_submission_private.submission_limits where kind = 'unregistered_place';
    if not found or not limits.enabled then
        return pg_catalog.jsonb_build_object('allowed', false, 'status', 503, 'code', 'REPORT_SUBMISSION_UNAVAILABLE', 'retry_after_seconds', 30);
    end if;
    current_time_utc := pg_catalog.clock_timestamp();
    minute_start := pg_catalog.date_trunc('minute', current_time_utc);
    day_start := pg_catalog.date_trunc('day', current_time_utc at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
    actor_label := case when p_actor_uid is not null then 'user:' || p_actor_uid::text else 'ip:' || pg_catalog.lower(p_actor_ip) end;
    actor_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to(actor_label, 'UTF8'), limits.digest_secret, 'sha256'), 'hex');
    actors := array['', '', actor_digest, actor_digest];
    starts := array[minute_start, day_start, minute_start, day_start];
    expiries := array[minute_start + interval '1 minute', day_start + interval '1 day', minute_start + interval '1 minute', day_start + interval '1 day'];
    maxima := array[limits.global_minute_limit, limits.global_daily_limit, limits.actor_minute_limit, limits.actor_daily_limit];
    for index in 1..4 loop
        select consumed into consumed_units from report_submission_private.place_validation_counters
        where scope = scopes[index] and actor_key = actors[index] and window_start = starts[index];
        if coalesce(consumed_units, 0) >= maxima[index] then
            retry_seconds := greatest(retry_seconds, pg_catalog.ceil(extract(epoch from expiries[index] - current_time_utc))::integer);
        end if;
    end loop;
    if retry_seconds > 0 then
        return pg_catalog.jsonb_build_object('allowed', false, 'status', 429, 'code', 'REPORT_RATE_LIMITED', 'retry_after_seconds', retry_seconds);
    end if;
    for index in 1..4 loop
        insert into report_submission_private.place_validation_counters as counter (scope, actor_key, window_start, expires_at, consumed)
        values (scopes[index], actors[index], starts[index], expiries[index], 1)
        on conflict (scope, actor_key, window_start) do update set consumed = counter.consumed + 1;
    end loop;
    delete from report_submission_private.place_validation_counters where ctid in (
        select ctid from report_submission_private.place_validation_counters where expires_at < current_time_utc order by expires_at limit 32
    );
    return pg_catalog.jsonb_build_object('allowed', true);
end;
$function$;

-- Only the Edge Function supplies verified identity and provider-derived IDs.
create function public.submit_verified_place_report(p_provider text, p_place_id text, p_actor_uid uuid, p_actor_ip text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
    canonical_url text;
    report_id uuid;
    previous_claims text := pg_catalog.current_setting('request.jwt.claims', true);
    previous_headers text := pg_catalog.current_setting('request.headers', true);
begin
    perform report_submission_private.require_place_report_actor(p_actor_uid, p_actor_ip);
    if p_place_id is null or p_place_id !~ '^[1-9][0-9]{0,19}$' or p_provider is null or p_provider not in ('naver', 'kakao') then
        raise exception 'invalid verified place' using errcode = '22023';
    end if;
    canonical_url := case p_provider
        when 'naver' then 'https://map.naver.com/p/entry/place/' || p_place_id
        when 'kakao' then 'https://place.map.kakao.com/' || p_place_id
    end;
    perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
        'role', case when p_actor_uid is null then 'anon' else 'authenticated' end,
        'sub', p_actor_uid
    )::text, true);
    perform pg_catalog.set_config('request.headers', pg_catalog.jsonb_build_object('x-forwarded-for', coalesce(p_actor_ip, 'shared-anonymous'))::text, true);
    insert into public.unregistered_place_reports(place_url) values (canonical_url) returning id into report_id;
    perform pg_catalog.set_config('request.jwt.claims', coalesce(previous_claims, ''), true);
    perform pg_catalog.set_config('request.headers', coalesce(previous_headers, ''), true);
    return pg_catalog.jsonb_build_object('status', case when report_id is null then 'duplicate' else 'submitted' end);
end;
$function$;

revoke all on function report_submission_private.require_place_report_actor(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.reserve_place_report_validation(uuid, text) from public, anon, authenticated;
revoke all on function public.submit_verified_place_report(text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.reserve_place_report_validation(uuid, text) to service_role;
grant execute on function public.submit_verified_place_report(text, text, uuid, text) to service_role;

drop policy "Anyone can submit unregistered place reports" on public.unregistered_place_reports;
revoke all on public.unregistered_place_reports from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
