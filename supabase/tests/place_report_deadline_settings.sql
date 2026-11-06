begin;
set local role anon;
set local statement_timeout='3s';
select set_config('request.method','GET',true),set_config('request.path','/unregistered_place_reports',true);
select public.prepare_place_report_request();
do $test$ begin
    if current_setting('statement_timeout') <> '3s' then raise exception '조회 요청의 제한 시간이 변경됐습니다'; end if;
end $test$;
select set_config('request.method','POST',true),set_config('request.path','/ramen_shops',true);
select public.prepare_place_report_request();
do $test$ begin
    if current_setting('statement_timeout') <> '3s' then raise exception '다른 API의 제한 시간이 변경됐습니다'; end if;
end $test$;
select set_config('request.path','/unregistered_place_reports',true);
select public.prepare_place_report_request();
do $test$ begin
    if current_setting('statement_timeout') <> '8s' then raise exception '기존 제보 INSERT의 제한 시간이 적용되지 않았습니다'; end if;
end $test$;
rollback;
select true as report_route_deadline_is_scoped;
