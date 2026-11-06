begin;

-- Only the legacy report INSERT needs to wait for external map verification.
create function public.prepare_place_report_request()
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
    if pg_catalog.current_setting('request.method',true) = 'POST'
        and pg_catalog.current_setting('request.path',true) = '/unregistered_place_reports' then
        perform pg_catalog.set_config('statement_timeout','8s',true);
    end if;
end;
$function$;
revoke all on function public.prepare_place_report_request() from public;
grant execute on function public.prepare_place_report_request() to anon, authenticated, service_role;

-- Refuse to overwrite a hook installed by another deployment.
do $guard$
begin
    if exists (
        select 1 from pg_catalog.pg_db_role_setting settings
        join pg_catalog.pg_roles role on role.oid=settings.setrole
        cross join lateral pg_catalog.unnest(settings.setconfig) item
        where role.rolname='authenticator' and item like 'pgrst.db_pre_request=%'
            and item not in ('pgrst.db_pre_request=','pgrst.db_pre_request=public.prepare_place_report_request')
    ) then
        raise exception 'existing PostgREST pre-request hook must be preserved';
    end if;
end;
$guard$;
alter role authenticator set pgrst.db_pre_request='public.prepare_place_report_request';

create or replace function report_submission_private.verify_place_report_url(place_url text, actor_uid uuid, actor_ip text)
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
    -- This route has an 8s API deadline; the installed app allows 10s.
    select coalesce(pg_catalog.jsonb_object_agg(curlopt,value),'{}'::jsonb) into previous_options from private.http_list_curlopt();
    perform private.http_reset_curlopt();
    perform private.http_set_curlopt('CURLOPT_TIMEOUT_MS','7000');
    perform private.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS','1500');
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

notify pgrst, 'reload config';
notify pgrst, 'reload schema';
commit;
