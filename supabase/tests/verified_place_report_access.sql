-- Original INSERT protocol, real provider verification and access boundaries.
-- Report rows and pg_net notification requests are rolled back; validation
-- attempt budgets intentionally commit in the validator's separate transaction.
begin;
set local statement_timeout='12s';
do $test$
declare
    role_name text;
    denied boolean;
    writes integer;
    rows_before bigint;
    canonical text := 'https://place.map.kakao.com/1200130562';
begin
    if pg_catalog.to_regprocedure('public.submit_verified_place_report(text,text,uuid,text)') is not null then
        raise exception 'obsolete persistence RPC remains';
    end if;
    foreach role_name in array array['anon','authenticated'] loop
        if not pg_catalog.has_column_privilege(role_name,'public.unregistered_place_reports','place_url','INSERT') then
            raise exception 'legacy INSERT permission missing for %',role_name;
        end if;
        if pg_catalog.has_column_privilege(role_name,'public.unregistered_place_reports','created_at','INSERT')
            or pg_catalog.has_function_privilege(role_name,'public.read_place_report_validation_key()','EXECUTE')
            or pg_catalog.has_function_privilege(role_name,'public.reserve_place_report_validation(uuid,text)','EXECUTE') then
            raise exception 'internal privilege exposed to %',role_name;
        end if;
        execute pg_catalog.format('set local role %I',role_name);
        denied := false;
        begin
            perform public.read_place_report_validation_key();
        exception when insufficient_privilege then denied := true;
        end;
        if not denied then raise exception 'private signing key exposed'; end if;
        denied := false;
        begin
            insert into public.unregistered_place_reports(place_url,created_at) values (canonical,now());
        exception when insufficient_privilege then denied := true;
        end;
        if not denied then raise exception 'caller-controlled server metadata allowed'; end if;
        denied := false;
        begin
            insert into public.unregistered_place_reports(place_url) values ('https://naver.me/test');
        exception when invalid_parameter_value then denied := true;
        end;
        if not denied then raise exception 'invalid short link accepted'; end if;
        reset role;
    end loop;

    select count(*) into rows_before from public.unregistered_place_reports where place_url=canonical;
    set local role anon;
    perform pg_catalog.set_config('request.jwt.claims','{"role":"anon"}',true);
    perform pg_catalog.set_config('request.headers','{"x-forwarded-for":"203.0.113.199"}',true);
    insert into public.unregistered_place_reports(place_url) values ('https://kko.to/i2sQooNyPb');
    get diagnostics writes=row_count;
    reset role;
    if (select count(*) from public.unregistered_place_reports where place_url=canonical) <> rows_before+writes then
        raise exception 'verified link was not canonicalized';
    end if;
    set local role anon;
    insert into public.unregistered_place_reports(place_url) values (canonical);
    get diagnostics writes=row_count;
    reset role;
    if writes <> 0 then raise exception 'canonical duplicate was not suppressed'; end if;
end;
$test$;
rollback;
select true as legacy_insert_verification_checks_passed;
