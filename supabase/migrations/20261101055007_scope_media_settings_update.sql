begin;
create or replace function public.configure_media_storage(p_read boolean,p_write boolean,p_legacy boolean default true) returns void
language plpgsql security definer set search_path = '' as $$
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    update media_private.settings set read_enabled=p_read,write_enabled=p_write,legacy_required=p_legacy where singleton=true;
end;
$$;
commit;
