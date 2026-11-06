create schema report_submission_private;
revoke all on schema report_submission_private from public, anon, authenticated;
grant usage on schema report_submission_private to service_role;

create table report_submission_private.submission_limits (
    kind text primary key check (kind in ('feedback', 'shop_information', 'unregistered_place')),
    global_minute_limit integer not null default 10 check (global_minute_limit between 1 and 10000),
    global_daily_limit integer not null default 100 check (global_daily_limit between 1 and 100000),
    actor_minute_limit integer not null default 3 check (actor_minute_limit between 1 and 10000),
    actor_daily_limit integer not null default 10 check (actor_daily_limit between 1 and 100000),
    enabled boolean not null default true,
    digest_secret bytea not null default extensions.gen_random_bytes(32) check (octet_length(digest_secret) = 32)
);
create table report_submission_private.submission_counters (
    kind text not null references report_submission_private.submission_limits(kind),
    scope text not null check (scope in ('global_minute', 'global_day', 'actor_minute', 'actor_day')),
    actor_key text not null check (actor_key = '' or actor_key ~ '^[a-f0-9]{64}$'),
    window_start timestamptz not null,
    expires_at timestamptz not null,
    consumed integer not null check (consumed > 0),
    primary key (kind, scope, actor_key, window_start)
);
create table report_submission_private.recent_submissions (
    kind text not null references report_submission_private.submission_limits(kind),
    fingerprint text not null check (fingerprint ~ '^[a-f0-9]{64}$'),
    expires_at timestamptz not null,
    primary key (kind, fingerprint)
);
create index submission_counters_expiry on report_submission_private.submission_counters(expires_at);
create index recent_submissions_expiry on report_submission_private.recent_submissions(expires_at);
alter table report_submission_private.submission_limits enable row level security;
alter table report_submission_private.submission_counters enable row level security;
alter table report_submission_private.recent_submissions enable row level security;
revoke all on all tables in schema report_submission_private from public, anon, authenticated, service_role;
grant select (kind, global_minute_limit, global_daily_limit, actor_minute_limit, actor_daily_limit, enabled)
    on report_submission_private.submission_limits to service_role;
grant select on report_submission_private.submission_counters, report_submission_private.recent_submissions to service_role;
insert into report_submission_private.submission_limits(kind) values ('feedback'), ('shop_information'), ('unregistered_place');

create function report_submission_private.is_valid_report_url(value text)
returns boolean language sql immutable security invoker set search_path = ''
as $function$
    select value is not null and char_length(value) between 1 and 2048
        and value ~* '^https?://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+(:[0-9]{1,5})?([/?#][^[:space:][:cntrl:]]*)?$'
        and coalesce(substring(value from '(?i)^https?://[^/?:#]+:([0-9]{1,5})')::integer between 1 and 65535, true);
$function$;

-- Only a validated row trigger calls this helper. Never trust caller-supplied
-- created_at, ids, user metadata or client ids for quotas or deduplication.
create function report_submission_private.admit_submission(submission_kind text, canonical_payload text)
returns boolean language plpgsql security definer set search_path = ''
as $function$
declare
    claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
    caller_role text := claims ->> 'role';
    policy report_submission_private.submission_limits%rowtype;
    headers jsonb;
    address text;
    forwarded text[];
    actor_label text;
    actor_digest text;
    payload_digest text;
    current_time_utc timestamptz;
    minute_start timestamptz;
    day_start timestamptz;
    scopes text[] := array['global_minute', 'global_day', 'actor_minute', 'actor_day'];
    actors text[];
    starts timestamptz[];
    expiries timestamptz[];
    maxima integer[];
    consumed_units integer;
    retry_seconds integer := 0;
    index integer;
begin
    -- Trusted service/SQL maintenance keeps its existing workflow. Public
    -- anon and authenticated submissions share hard project-wide limits.
    if caller_role is null or caller_role = 'service_role' then return true; end if;
    if caller_role not in ('anon', 'authenticated') then
        raise exception 'report submission is not permitted' using errcode = '42501';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.report-submission.' || submission_kind, 0));
    select * into policy from report_submission_private.submission_limits where kind = submission_kind;
    if not found or not policy.enabled then
        raise sqlstate 'PGRST'
            using message = '{"code":"REPORT_SUBMISSION_UNAVAILABLE","message":"Report submission temporarily unavailable"}',
                detail = '{"status":503,"headers":{"Retry-After":"30","Cache-Control":"no-store"}}';
    end if;

    current_time_utc := pg_catalog.clock_timestamp();
    payload_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to('payload:' || canonical_payload, 'UTF8'), policy.digest_secret, 'sha256'), 'hex');
    if exists (select 1 from report_submission_private.recent_submissions
        where kind = submission_kind and fingerprint = payload_digest and expires_at > current_time_utc) then
        return false;
    end if;
    if auth.uid() is not null then
        actor_label := 'user:' || auth.uid()::text;
    else
        headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
        forwarded := pg_catalog.string_to_array(headers ->> 'x-forwarded-for', ',');
        address := pg_catalog.btrim(coalesce(forwarded[pg_catalog.array_length(forwarded, 1)], headers ->> 'x-real-ip', ''));
        if char_length(address) not between 1 and 64 or address !~ '^[0-9a-fA-F.:]+$' then address := 'shared-anonymous'; end if;
        actor_label := 'ip:' || pg_catalog.lower(address);
    end if;
    actor_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to(actor_label, 'UTF8'), policy.digest_secret, 'sha256'), 'hex');
    minute_start := pg_catalog.date_trunc('minute', current_time_utc);
    day_start := pg_catalog.date_trunc('day', current_time_utc at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
    actors := array['', '', actor_digest, actor_digest];
    starts := array[minute_start, day_start, minute_start, day_start];
    expiries := array[minute_start + interval '1 minute', day_start + interval '1 day', minute_start + interval '1 minute', day_start + interval '1 day'];
    maxima := array[policy.global_minute_limit, policy.global_daily_limit, policy.actor_minute_limit, policy.actor_daily_limit];
    for index in 1..4 loop
        select consumed into consumed_units from report_submission_private.submission_counters
        where kind = submission_kind and scope = scopes[index] and actor_key = actors[index] and window_start = starts[index];
        if coalesce(consumed_units, 0) >= maxima[index] then
            retry_seconds := greatest(retry_seconds, pg_catalog.ceil(extract(epoch from expiries[index] - current_time_utc))::integer);
        end if;
    end loop;
    if retry_seconds > 0 then
        raise sqlstate 'PGRST'
            using message = '{"code":"REPORT_RATE_LIMITED","message":"Report submission limit reached"}',
                detail = pg_catalog.jsonb_build_object('status', 429, 'headers', pg_catalog.jsonb_build_object('Retry-After', retry_seconds::text, 'Cache-Control', 'no-store'))::text;
    end if;
    for index in 1..4 loop
        insert into report_submission_private.submission_counters as counter (kind, scope, actor_key, window_start, expires_at, consumed)
        values (submission_kind, scopes[index], actors[index], starts[index], expiries[index], 1)
        on conflict (kind, scope, actor_key, window_start) do update set consumed = counter.consumed + 1;
    end loop;
    insert into report_submission_private.recent_submissions (kind, fingerprint, expires_at)
    values (submission_kind, payload_digest, current_time_utc + interval '24 hours')
    on conflict (kind, fingerprint) do update set expires_at = excluded.expires_at;
    delete from report_submission_private.submission_counters where ctid in (
        select ctid from report_submission_private.submission_counters where expires_at < current_time_utc order by expires_at limit 32
    );
    delete from report_submission_private.recent_submissions where ctid in (
        select ctid from report_submission_private.recent_submissions where expires_at < current_time_utc order by expires_at limit 32
    );
    return true;
end;
$function$;

create function report_submission_private.guard_submission()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
    lane text;
    payload text;
    sorted_fields text[];
begin
    if tg_table_schema <> 'public' then raise exception 'unexpected report table'; end if;
    case tg_table_name
        when 'feedback_submissions' then
            lane := 'feedback';
            new.message := pg_catalog.btrim(new.message);
            if new.message is null or char_length(new.message) > 4000
                or char_length(coalesce(new.attachment_path, '')) > 1024
                or char_length(coalesce(new.shop_name, '')) > 250
                or char_length(coalesce(new.shop_address, '')) > 500
                or char_length(coalesce(new.shop_kakao_place_url, '')) > 2048 then
                raise exception 'invalid feedback content' using errcode = '22023';
            end if;
            if new.feedback_type = 'news_report' then
                if new.message <> '' and not report_submission_private.is_valid_report_url(new.message) then
                    raise exception 'invalid news report URL' using errcode = '22023';
                end if;
                if new.message = '' and new.attachment_path is null then
                    raise exception 'news report requires source URL or evidence' using errcode = '22023';
                end if;
                -- Preserve the existing permanent source-URL duplicate rule.
                if new.message <> '' and exists (select 1 from public.feedback_submissions f where f.feedback_type = 'news_report' and f.message = new.message) then return null; end if;
                payload := pg_catalog.jsonb_build_object('type', 'news_report', 'source', new.message, 'attachment', case when new.message = '' then new.attachment_path else null end)::text;
            else
                payload := pg_catalog.jsonb_build_object('type', new.feedback_type, 'message', new.message, 'name', new.shop_name, 'address', new.shop_address, 'place_url', new.shop_kakao_place_url)::text;
            end if;
        when 'shop_information_reports' then
            lane := 'shop_information';
            if new.shop_name is null or char_length(new.shop_name) not between 1 and 250
                or new.description is null or char_length(new.description) > 4000
                or new.wrong_fields is null or cardinality(new.wrong_fields) > 9 then
                raise exception 'invalid shop information report' using errcode = '22023';
            end if;
            select coalesce(array_agg(field order by field), array[]::text[]) into sorted_fields
                from (select distinct field from unnest(new.wrong_fields) field) fields;
            payload := pg_catalog.jsonb_build_object('shop_id', new.shop_id, 'fields', sorted_fields, 'description', pg_catalog.btrim(pg_catalog.regexp_replace(new.description, '[[:space:]]+', ' ', 'g')))::text;
        when 'unregistered_place_reports' then
            lane := 'unregistered_place';
            new.place_url := nullif(pg_catalog.btrim(new.place_url), '');
            if new.place_url is not null and not report_submission_private.is_valid_report_url(new.place_url) then
                raise exception 'invalid place report URL' using errcode = '22023';
            end if;
            if (new.lat is null) <> (new.lng is null)
                or (new.lat is not null and not (new.lat between -90 and 90 and new.lng between -180 and 180))
                or (new.place_url is null and new.lat is null) then
                raise exception 'invalid place report coordinates' using errcode = '22023';
            end if;
            payload := pg_catalog.jsonb_build_object('url', new.place_url, 'lat', case when new.place_url is null then round(new.lat::numeric, 6) else null end, 'lng', case when new.place_url is null then round(new.lng::numeric, 6) else null end)::text;
        else
            raise exception 'unexpected report table';
    end case;
    if not report_submission_private.admit_submission(lane, payload) then return null; end if;
    return new;
end;
$function$;
revoke all on all functions in schema report_submission_private from public, anon, authenticated, service_role;

create trigger a_guard_public_report_submission before insert on public.feedback_submissions
    for each row execute function report_submission_private.guard_submission();
create trigger a_guard_public_report_submission before insert on public.shop_information_reports
    for each row execute function report_submission_private.guard_submission();
create trigger a_guard_public_report_submission before insert on public.unregistered_place_reports
    for each row execute function report_submission_private.guard_submission();

comment on schema report_submission_private is 'Server-only bounded report quotas and keyed duplicate fingerprints. No raw client IP or report content is retained here.';

CREATE OR REPLACE FUNCTION public.submit_news_report(p_source_url text DEFAULT NULL::text, p_attachment_path text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'storage'
AS $function$
begin
    if nullif(btrim(p_source_url), '') is null and p_attachment_path is null then
        raise exception 'news report requires source URL or evidence';
    end if;

    if p_attachment_path is not null then
        perform community_private.require_live_user();

        if not exists (
            select 1
            from storage.objects
            where bucket_id = 'news-report-evidence'
                and name = p_attachment_path
                and owner_id = auth.uid()::text
        ) then
            raise exception 'news report evidence is not owned by the reporter'
                using errcode = '42501';
        end if;
    end if;

    if p_attachment_path is not null and not exists (
        select 1
        from storage.objects
        where bucket_id = 'news-report-evidence'
            and name = p_attachment_path
    ) then
        raise exception 'news report evidence does not exist';
    end if;

    if nullif(btrim(p_source_url), '') is not null then
        insert into public.feedback_submissions (feedback_type, message, attachment_path)
        values ('news_report', btrim(p_source_url), p_attachment_path)
        on conflict (message)
            where feedback_type = 'news_report' and nullif(btrim(message), '') is not null
            do nothing;

        if not found then
            return 'duplicate';
        end if;
    else
        insert into public.feedback_submissions (feedback_type, message, attachment_path)
        values ('news_report', '', p_attachment_path);
        if not found then return 'duplicate'; end if;
    end if;

    return 'submitted';
end;
$function$;

