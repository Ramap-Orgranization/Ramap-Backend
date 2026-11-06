begin;

create function report_submission_private.is_valid_place_report_url(value text)
returns boolean
language sql
immutable
security invoker
set search_path = ''
as $function$
    select report_submission_private.is_valid_report_url(value) and value ~* any (array[
        '^https://naver[.]me/[a-z0-9]{8}/?([?][^[:space:][:cntrl:]#]*)?$',
        '^https://kko[.]to/[a-z0-9_-]{8,64}/?([?][^[:space:][:cntrl:]#]*)?$',
        '^https://place[.]map[.]kakao[.]com/[1-9][0-9]*/?([?][^[:space:][:cntrl:]#]*)?$',
        '^https://map[.]kakao[.]com/link/map/[1-9][0-9]*/?([?][^[:space:][:cntrl:]#]*)?$',
        '^https://applink[.]map[.]kakao[.]com/(place)?[?]([^[:space:][:cntrl:]#]*&)?id=[1-9][0-9]*(&[^[:space:][:cntrl:]#]*)?$',
        '^https://map[.]naver[.]com/(p/|v5/)?entry/place/[1-9][0-9]*/?([?][^[:space:][:cntrl:]#]*)?$',
        '^https://map[.]naver[.]com(/(p|v5))?/?[?]([^[:space:][:cntrl:]#]*&)?pinId=[1-9][0-9]*(&[^[:space:][:cntrl:]#]*)?$',
        '^https://m[.]place[.]naver[.]com/(restaurant|place|cafe|accommodation)/[1-9][0-9]*(/[a-z]+)?/?([?][^[:space:][:cntrl:]#]*)?$'
    ]);
$function$;

create function report_submission_private.guard_place_report_url()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
    if nullif(pg_catalog.btrim(new.place_url), '') is not null
        and not report_submission_private.is_valid_place_report_url(pg_catalog.btrim(new.place_url)) then
        raise exception 'invalid place report URL' using errcode = '22023';
    end if;
    return new;
end;
$function$;

revoke all on function report_submission_private.is_valid_place_report_url(text) from public, anon, authenticated, service_role;
revoke all on function report_submission_private.guard_place_report_url() from public, anon, authenticated, service_role;

-- Validate before duplicate suppression, quota consumption and notifications.
create trigger a_check_place_report_url before insert on public.unregistered_place_reports
    for each row execute function report_submission_private.guard_place_report_url();

commit;
