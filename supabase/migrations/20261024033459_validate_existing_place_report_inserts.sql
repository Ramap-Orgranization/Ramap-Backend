begin;

create table report_submission_private.validation_gateway (
    singleton boolean primary key default true check (singleton),
    signing_key bytea not null default extensions.gen_random_bytes(32) check (octet_length(signing_key) = 32),
    endpoint text not null check (endpoint ~ '^https://[a-z0-9]+[.]supabase[.]co/functions/v1/validate-place-report$')
);
alter table report_submission_private.validation_gateway enable row level security;
revoke all on report_submission_private.validation_gateway from public, anon, authenticated, service_role;
insert into report_submission_private.validation_gateway(endpoint)
values ('https://clbhayqiwjawaawvrhcq.supabase.co/functions/v1/validate-place-report');

create function public.read_place_report_validation_key()
returns jsonb language sql stable security definer set search_path = ''
as $function$
    select pg_catalog.jsonb_build_object('key', pg_catalog.encode(signing_key, 'hex'))
    from report_submission_private.validation_gateway where singleton;
$function$;
revoke all on function public.read_place_report_validation_key() from public, anon, authenticated;
grant execute on function public.read_place_report_validation_key() to service_role;

create function report_submission_private.restore_http_options(options jsonb)
returns void language plpgsql security invoker set search_path = ''
as $function$
declare item record;
begin
    perform private.http_reset_curlopt();
    for item in select * from pg_catalog.jsonb_each_text(options) loop
        perform private.http_set_curlopt(item.key,item.value);
    end loop;
end;
$function$;
revoke all on function report_submission_private.restore_http_options(jsonb) from public, anon, authenticated, service_role;

create function report_submission_private.verify_place_report_url(place_url text, actor_uid uuid, actor_ip text)
returns text language plpgsql security definer set search_path = ''
as $function$
declare
    gateway report_submission_private.validation_gateway%rowtype;
    timestamp_text text := pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint::text;
    payload text;
    signature text;
    response private.http_response;
    result jsonb;
    retry_seconds integer := 30;
    previous_options jsonb;
begin
    select * into strict gateway from report_submission_private.validation_gateway where singleton;
    payload := pg_catalog.jsonb_build_object('place_url', place_url, 'actor_uid', actor_uid, 'actor_ip', actor_ip)::text;
    signature := pg_catalog.encode(extensions.hmac(pg_catalog.convert_to(timestamp_text || E'\n' || payload, 'UTF8'), gateway.signing_key, 'sha256'), 'hex');
    -- Stay below the existing anonymous role's three-second statement timeout.
    select coalesce(pg_catalog.jsonb_object_agg(curlopt,value),'{}'::jsonb) into previous_options from private.http_list_curlopt();
    perform private.http_reset_curlopt();
    perform private.http_set_curlopt('CURLOPT_TIMEOUT_MS','2400');
    perform private.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS','500');
    begin
        select * into response from private.http(row(
            'POST', gateway.endpoint,
            array[
                row('X-Ramap-Timestamp', timestamp_text)::private.http_header,
                row('X-Ramap-Signature', signature)::private.http_header
            ],
            'application/json', payload
        )::private.http_request);
    exception when query_canceled then
        perform report_submission_private.restore_http_options(previous_options);
        raise;
    when others then
        perform report_submission_private.restore_http_options(previous_options);
        raise sqlstate 'PGRST' using
            message = '{"code":"PLACE_VALIDATION_UNAVAILABLE","message":"Place validation temporarily unavailable"}',
            detail = '{"status":503,"headers":{"Retry-After":"30","Cache-Control":"no-store"}}';
    end;
    perform report_submission_private.restore_http_options(previous_options);
    if response.status = 400 then
        raise exception 'invalid place report URL' using errcode = '22023';
    end if;
    if response.status = 429 then
        select coalesce(max(case when h.value ~ '^[0-9]{1,5}$' then greatest(1,least(h.value::integer,86400)) end),30)
        into retry_seconds from unnest(response.headers) h where pg_catalog.lower(h.field)='retry-after';
        raise sqlstate 'PGRST' using
            message = '{"code":"REPORT_RATE_LIMITED","message":"Report submission limit reached"}',
            detail = pg_catalog.jsonb_build_object('status',429,'headers',pg_catalog.jsonb_build_object('Retry-After',retry_seconds::text,'Cache-Control','no-store'))::text;
    end if;
    if response.status <> 200 or pg_catalog.octet_length(response.content) > 4096 then
        raise sqlstate 'PGRST' using
            message = '{"code":"PLACE_VALIDATION_UNAVAILABLE","message":"Place validation temporarily unavailable"}',
            detail = '{"status":503,"headers":{"Retry-After":"30","Cache-Control":"no-store"}}';
    end if;
    begin
        result := response.content::jsonb;
    exception when others then
        raise sqlstate 'PGRST' using
            message = '{"code":"PLACE_VALIDATION_UNAVAILABLE","message":"Place validation temporarily unavailable"}',
            detail = '{"status":503,"headers":{"Retry-After":"30","Cache-Control":"no-store"}}';
    end;
    if coalesce(result->>'provider','') not in ('naver','kakao')
        or coalesce(result->>'place_id','') !~ '^[1-9][0-9]{0,19}$' then
        raise sqlstate 'PGRST' using
            message = '{"code":"PLACE_VALIDATION_UNAVAILABLE","message":"Place validation temporarily unavailable"}',
            detail = '{"status":503,"headers":{"Retry-After":"30","Cache-Control":"no-store"}}';
    end if;
    return case result->>'provider'
        when 'naver' then 'https://map.naver.com/p/entry/place/' || (result->>'place_id')
        when 'kakao' then 'https://place.map.kakao.com/' || (result->>'place_id')
    end;
end;
$function$;

create function report_submission_private.validate_place_report_insert()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
    headers jsonb := coalesce(nullif(pg_catalog.current_setting('request.headers', true),''),'{}')::jsonb;
    forwarded text[] := pg_catalog.string_to_array(headers->>'x-forwarded-for', ',');
    address text;
begin
    if nullif(pg_catalog.btrim(new.place_url),'') is null then
        raise exception 'place report requires a map link' using errcode = '22023';
    end if;
    address := pg_catalog.btrim(coalesce(forwarded[pg_catalog.array_length(forwarded,1)],headers->>'x-real-ip','shared-anonymous'));
    if char_length(address) not between 1 and 64 or address !~ '^[0-9a-fA-F.:]+$' then address := 'shared-anonymous'; end if;
    new.place_url := report_submission_private.verify_place_report_url(pg_catalog.btrim(new.place_url),auth.uid(),pg_catalog.lower(address));
    return new;
end;
$function$;
revoke all on function report_submission_private.verify_place_report_url(text,uuid,text) from public, anon, authenticated, service_role;
revoke all on function report_submission_private.validate_place_report_insert() from public, anon, authenticated, service_role;

-- Canonicalize after provider verification, then deduplicate and admit the row.
alter trigger a_guard_public_report_submission on public.unregistered_place_reports rename to c_guard_public_report_submission;
create trigger b_validate_place_report_insert before insert on public.unregistered_place_reports
    for each row execute function report_submission_private.validate_place_report_insert();

drop function public.submit_verified_place_report(text,text,uuid,text);
grant insert (place_url) on public.unregistered_place_reports to anon, authenticated;
create policy "Users submit place links through mandatory validation"
on public.unregistered_place_reports for insert to anon, authenticated
with check (place_url is not null and char_length(place_url) between 1 and 2048);

notify pgrst, 'reload schema';
commit;
