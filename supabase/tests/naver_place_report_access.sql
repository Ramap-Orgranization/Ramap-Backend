-- Real-provider regression for the reported Naver link. Report rows and queued
-- Discord notifications are rolled back; validation-attempt quotas still apply.
begin;
set local statement_timeout='8s';
do $test$
declare
    canonical constant text := 'https://map.naver.com/p/entry/place/1690614480';
    rows_before bigint;
    written integer;
begin
    select count(*) into rows_before from public.unregistered_place_reports where place_url=canonical;
    set local role anon;
    perform pg_catalog.set_config('request.jwt.claims','{"role":"anon"}',true);
    perform pg_catalog.set_config('request.headers','{"x-forwarded-for":"203.0.113.196"}',true);
    insert into public.unregistered_place_reports(place_url) values(canonical);
    get diagnostics written=row_count;
    reset role;
    if (select count(*) from public.unregistered_place_reports where place_url=canonical) <> rows_before+written then
        raise exception '검증된 네이버 매장 링크가 저장되지 않았습니다';
    end if;
end;
$test$;
rollback;

begin;
set local statement_timeout='8s';
do $test$
begin
    set local role anon;
    perform pg_catalog.set_config('request.jwt.claims','{"role":"anon"}',true);
    perform pg_catalog.set_config('request.headers','{"x-forwarded-for":"203.0.113.196"}',true);
    begin
        insert into public.unregistered_place_reports(place_url) values('https://map.naver.com/p/entry/place/999999999');
        raise exception '존재하지 않는 네이버 매장 링크가 허용됐습니다';
    exception when invalid_parameter_value then null;
    end;
    reset role;
end;
$test$;
rollback;
select true as naver_report_insert_and_rejection_passed;
