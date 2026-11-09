-- Protocol 2 supports opening a registered operating notice directly.
alter table public.push_registrations
    drop constraint push_registrations_supported_protocol_version_check;
alter table public.push_registrations
    add constraint push_registrations_supported_protocol_version_check
    check (supported_protocol_version between 0 and 2);

create or replace function public.register_push_registration_protocol(registration_identifier text, device_platform text, registration_target_type text, expected_account_id uuid, supported_protocol_version integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
    if auth.uid() is null or auth.uid() is distinct from expected_account_id then raise exception 'notification_account_mismatch'; end if;
    if supported_protocol_version is null or supported_protocol_version not between 0 and 2 then raise exception 'unsupported_notification_protocol'; end if;
    perform push_registration_private.register_identifier(registration_identifier,device_platform,registration_target_type);
    update public.push_registrations p set supported_protocol_version=register_push_registration_protocol.supported_protocol_version
    where p.identifier=registration_identifier and p.user_id=auth.uid();
end;
$$;
revoke all on function public.register_push_registration_protocol(text,text,text,uuid,integer) from public,anon;
grant execute on function public.register_push_registration_protocol(text,text,text,uuid,integer) to authenticated;
