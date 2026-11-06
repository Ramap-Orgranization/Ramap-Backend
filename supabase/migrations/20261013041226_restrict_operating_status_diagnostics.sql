set local lock_timeout = '5s';
set local statement_timeout = '15s';

revoke all privileges on public.shop_operating_status from public, anon, authenticated;
revoke all privileges (
    shop_id, naver_place_id, status, source_url, checked_at, last_error,
    next_check_at, check_interval_minutes, check_reason, consecutive_failures
) on public.shop_operating_status from public, anon, authenticated;

grant select (shop_id, status, checked_at)
on public.shop_operating_status to anon, authenticated;

create view public.shop_operating_status_public with (security_invoker = true) as
select shop_id, status, checked_at
from public.shop_operating_status;

revoke all privileges on public.shop_operating_status_public
from public, anon, authenticated, service_role;
grant select on public.shop_operating_status_public to anon, authenticated, service_role;

comment on view public.shop_operating_status_public is
'Public read-only status and observation time. Caller RLS preserves hidden-shop visibility; worker diagnostics remain server-only.';

do $assertions$
begin
    if not (select relrowsecurity from pg_class where oid = 'public.shop_operating_status'::regclass) then
        raise exception 'Operating status must retain row-level security';
    end if;

    if exists (
        select 1
        from unnest(array['anon', 'authenticated']) as roles(role_name)
        cross join pg_attribute as column_info
        where column_info.attrelid = 'public.shop_operating_status'::regclass
          and column_info.attnum > 0 and not column_info.attisdropped
          and has_column_privilege(roles.role_name, column_info.attrelid, column_info.attnum, 'SELECT')
              is distinct from (column_info.attname = any(array['shop_id', 'status', 'checked_at']))
    ) then
        raise exception 'Public status reads must be restricted to the three public columns';
    end if;

    if exists (
        select 1
        from unnest(array['anon', 'authenticated']) as roles(role_name)
        cross join unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) as operations(privilege_name)
        where has_table_privilege(roles.role_name, 'public.shop_operating_status', operations.privilege_name)
    ) or exists (
        select 1
        from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) as operations(privilege_name)
        where not has_table_privilege('service_role', 'public.shop_operating_status', operations.privilege_name)
    ) then
        raise exception 'Only the server role may maintain the original status table';
    end if;

    if exists (
        select 1
        from unnest(array['anon', 'authenticated', 'service_role']) as roles(role_name)
        cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) as operations(privilege_name)
        where has_table_privilege(roles.role_name, 'public.shop_operating_status_public', operations.privilege_name)
    ) then
        raise exception 'The public status projection must be read-only';
    end if;
end;
$assertions$;

notify pgrst, 'reload schema';
