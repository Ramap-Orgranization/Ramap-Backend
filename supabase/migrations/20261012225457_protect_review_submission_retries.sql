create schema review_submission_private;
revoke all on schema review_submission_private from public, anon, authenticated;
grant usage on schema review_submission_private to service_role;

create table review_submission_private.settings (
    singleton boolean primary key default true check (singleton),
    actor_minute_limit integer not null default 3 check (actor_minute_limit between 1 and 10000),
    actor_daily_limit integer not null default 30 check (actor_daily_limit between 1 and 100000),
    replay_window_seconds integer not null default 600 check (replay_window_seconds between 1 and 3600),
    enabled boolean not null default true,
    digest_secret bytea not null default extensions.gen_random_bytes(32) check (octet_length(digest_secret) = 32)
);
create table review_submission_private.counters (
    actor_key text not null check (actor_key ~ '^[a-f0-9]{64}$'),
    scope text not null check (scope in ('minute', 'day')),
    window_start timestamptz not null,
    expires_at timestamptz not null,
    consumed integer not null check (consumed > 0),
    primary key (actor_key, scope, window_start)
);
create table review_submission_private.receipts (
    actor_key text not null check (actor_key ~ '^[a-f0-9]{64}$'),
    payload_key text not null check (payload_key ~ '^[a-f0-9]{64}$'),
    review_id uuid not null references public.shop_reviews(id) on delete cascade,
    expires_at timestamptz not null,
    primary key (actor_key, payload_key)
);
create index review_submission_counters_expiry on review_submission_private.counters(expires_at);
create index review_submission_receipts_expiry on review_submission_private.receipts(expires_at);
create index review_submission_receipts_review on review_submission_private.receipts(review_id);
alter table review_submission_private.settings enable row level security;
alter table review_submission_private.counters enable row level security;
alter table review_submission_private.receipts enable row level security;
revoke all on all tables in schema review_submission_private from public, anon, authenticated, service_role;
grant select (singleton, actor_minute_limit, actor_daily_limit, replay_window_seconds, enabled)
    on review_submission_private.settings to service_role;
grant select on review_submission_private.counters, review_submission_private.receipts to service_role;
insert into review_submission_private.settings(singleton) values (true);

create function review_submission_private.reserve_submission(canonical_payload text)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare
    owner_id uuid := auth.uid();
    policy review_submission_private.settings%rowtype;
    actor_digest text;
    payload_digest text;
    previous_review_id uuid;
    current_time_utc timestamptz;
    starts timestamptz[];
    expiries timestamptz[];
    scopes text[] := array['minute', 'day'];
    maxima integer[];
    consumed_units integer;
    retry_seconds integer := 0;
    index integer;
begin
    if owner_id is null or canonical_payload is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.review-submit.' || owner_id::text, 0));
    select * into policy from review_submission_private.settings where singleton for share;
    if not found or not policy.enabled then
        raise sqlstate 'PGRST'
            using message = '{"code":"REVIEW_SUBMISSION_UNAVAILABLE","message":"Review submission temporarily unavailable"}',
                detail = '{"status":503,"headers":{"Retry-After":"30","Cache-Control":"no-store"}}';
    end if;
    current_time_utc := pg_catalog.clock_timestamp();
    actor_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to('user:' || owner_id::text, 'UTF8'), policy.digest_secret, 'sha256'), 'hex');
    payload_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to('payload:' || canonical_payload, 'UTF8'), policy.digest_secret, 'sha256'), 'hex');
    select r.review_id into previous_review_id
    from review_submission_private.receipts r join public.shop_reviews review on review.id = r.review_id
    where r.actor_key = actor_digest and r.payload_key = payload_digest
        and r.expires_at > current_time_utc and review.user_id = owner_id;
    if previous_review_id is not null then return previous_review_id; end if;

    starts := array[pg_catalog.date_trunc('minute', current_time_utc), pg_catalog.date_trunc('day', current_time_utc at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'];
    expiries := array[starts[1] + interval '1 minute', starts[2] + interval '1 day'];
    maxima := array[policy.actor_minute_limit, policy.actor_daily_limit];
    for index in 1..2 loop
        select consumed into consumed_units from review_submission_private.counters
        where actor_key = actor_digest and scope = scopes[index] and window_start = starts[index];
        if coalesce(consumed_units, 0) >= maxima[index] then
            retry_seconds := greatest(retry_seconds, pg_catalog.ceil(extract(epoch from expiries[index] - current_time_utc))::integer);
        end if;
    end loop;
    if retry_seconds > 0 then
        raise sqlstate 'PGRST'
            using message = '{"code":"REVIEW_RATE_LIMITED","message":"Review submission limit reached"}',
                detail = pg_catalog.jsonb_build_object('status', 429, 'headers', pg_catalog.jsonb_build_object('Retry-After', retry_seconds::text, 'Cache-Control', 'no-store'))::text;
    end if;
    for index in 1..2 loop
        insert into review_submission_private.counters as counter (actor_key, scope, window_start, expires_at, consumed)
        values (actor_digest, scopes[index], starts[index], expiries[index], 1)
        on conflict (actor_key, scope, window_start) do update set consumed = counter.consumed + 1;
    end loop;
    delete from review_submission_private.counters where ctid in (
        select ctid from review_submission_private.counters where expires_at < current_time_utc order by expires_at limit 32
    );
    delete from review_submission_private.receipts where ctid in (
        select ctid from review_submission_private.receipts where expires_at < current_time_utc order by expires_at limit 32
    );
    return null;
end;
$function$;

create function review_submission_private.remember_submission(canonical_payload text, submitted_review_id uuid)
returns void language plpgsql security definer set search_path = ''
as $function$
declare
    owner_id uuid := auth.uid();
    policy review_submission_private.settings%rowtype;
    actor_digest text;
    payload_digest text;
begin
    if owner_id is null or canonical_payload is null or not exists (
        select 1 from public.shop_reviews where id = submitted_review_id and user_id = owner_id
    ) then raise exception 'invalid review receipt' using errcode = '42501'; end if;
    select * into policy from review_submission_private.settings where singleton for share;
    if not found or not policy.enabled then raise exception 'review settings unavailable'; end if;
    actor_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to('user:' || owner_id::text, 'UTF8'), policy.digest_secret, 'sha256'), 'hex');
    payload_digest := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to('payload:' || canonical_payload, 'UTF8'), policy.digest_secret, 'sha256'), 'hex');
    insert into review_submission_private.receipts(actor_key, payload_key, review_id, expires_at)
    values (actor_digest, payload_digest, submitted_review_id, pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => policy.replay_window_seconds))
    on conflict (actor_key, payload_key) do update set review_id = excluded.review_id, expires_at = excluded.expires_at;
end;
$function$;
revoke all on all functions in schema review_submission_private from public, anon, authenticated, service_role;
comment on schema review_submission_private is 'Server-only review replay receipts and bounded per-account submission quotas. No raw user ID, token, IP or review body is retained.';

CREATE OR REPLACE FUNCTION public.submit_shop_review(p_shop_id uuid, p_body text, p_image_paths text[] DEFAULT '{}'::text[], p_is_public boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
declare review_id uuid;
declare image_path text;
declare image_object_id uuid;
declare canonical_payload text;
begin
    current_user_id := community_private.require_live_user();
    if p_shop_id is null
       or p_body is null or p_body <> btrim(p_body) or char_length(p_body) not between 5 and 30
       or p_is_public is null
       or p_image_paths is null or cardinality(p_image_paths) > 3
       or coalesce(array_ndims(p_image_paths), 1) <> 1
       or cardinality(p_image_paths) <> (select count(distinct path) from unnest(p_image_paths) path)
       or not public.shop_review_image_paths_belong_to_user(p_image_paths, current_user_id)
       or not exists (select 1 from public.ramen_shops where id = p_shop_id)
    then
        raise exception 'Invalid review';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.review-submit.' || current_user_id::text, 0));
    for image_path in
        select path from unnest(p_image_paths) path order by path
    loop
        perform pg_advisory_xact_lock(hashtextextended(image_path, 0));
        select id into image_object_id from storage.objects
        where bucket_id = 'shop-review-images' and name = image_path for update;
        if image_object_id is null then raise exception 'Review image not found'; end if;
    end loop;
    canonical_payload := pg_catalog.jsonb_build_object('shop_id', p_shop_id, 'body', p_body, 'image_paths', p_image_paths, 'is_public', p_is_public)::text;
    review_id := review_submission_private.reserve_submission(canonical_payload);
    if review_id is not null then return review_id; end if;
    if exists (
        select 1 from public.shop_reviews where image_paths && p_image_paths
    ) then
        raise exception 'Review image already submitted';
    end if;
    perform account_profile_private.fetch_or_create_my_profile(current_user_id);
    insert into public.shop_reviews(shop_id, user_id, body, image_paths, moderation_status, is_public)
    values (p_shop_id, current_user_id, p_body, p_image_paths, 'published', p_is_public) returning id into review_id;
    perform review_submission_private.remember_submission(canonical_payload, review_id);
    return review_id;
end;
$function$;
