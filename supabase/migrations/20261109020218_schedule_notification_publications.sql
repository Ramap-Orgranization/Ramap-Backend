-- Vault values are configured separately; no credential or project URL is stored
-- in the migration or cron command. Disabled/missing configuration sends nothing.
create function notification_private.request_dispatch() returns bigint
language plpgsql security invoker set search_path='' as $$
declare endpoint text; dispatch_secret text;
begin
    if not exists(select 1 from notification_private.settings where singleton and transport_enabled) then return null; end if;
    select decrypted_secret into endpoint from vault.decrypted_secrets where name='notification_publication_url';
    select decrypted_secret into dispatch_secret from vault.decrypted_secrets where name='notification_dispatch_secret';
    if endpoint is null or dispatch_secret is null then return null; end if;
    return net.http_post(url:=endpoint,headers:=jsonb_build_object('Content-Type','application/json','x-notification-dispatch-secret',dispatch_secret),body:='{"limit":20}'::jsonb,timeout_milliseconds:=10000);
end;
$$;
revoke all on function notification_private.request_dispatch() from public,anon,authenticated,service_role;
select cron.schedule('notification-publications','* * * * *','select notification_private.request_dispatch();');
