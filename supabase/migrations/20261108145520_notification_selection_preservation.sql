-- Catalog visibility controls editing, activation controls delivery. Neither erases consent.
create or replace function shop_notification_private.catalog_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    if TG_OP = 'DELETE' then raise exception 'notification_type_retirement_requires_deactivation'; end if;
    if TG_OP = 'UPDATE' and NEW.id <> OLD.id then raise exception 'notification_type_id_is_immutable'; end if;
    update shop_notification_private.catalog_revision set revision = revision + 1;
    return null;
end;
$$;

create or replace function public.fetch_shop_notification_settings(p_shop_id uuid, p_expected_account_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_account uuid; v_result jsonb;
begin
    v_account := shop_notification_private.validate_request(p_shop_id, p_expected_account_id);
    select jsonb_build_object(
        'account_id',v_account,'shop_id',p_shop_id,'catalog_revision',r.revision,
        'types',coalesce((select jsonb_agg(to_jsonb(c) order by c.display_order,c.id) from public.shop_notification_catalog c where c.is_active and c.is_visible),'[]'::jsonb),
        'has_effective_subscription',exists(select 1 from public.shop_notification_catalog c where c.is_active and ((c.id='event' and exists(select 1 from public.shop_event_notification_subscriptions e where e.user_id=v_account and e.shop_id=p_shop_id)) or exists(select 1 from public.shop_operating_notification_subscriptions o where o.user_id=v_account and o.shop_id=p_shop_id and o.type_id=c.id))),
        'has_hidden_effective_subscription',exists(select 1 from public.shop_notification_catalog c where c.is_active and not c.is_visible and ((c.id='event' and exists(select 1 from public.shop_event_notification_subscriptions e where e.user_id=v_account and e.shop_id=p_shop_id)) or exists(select 1 from public.shop_operating_notification_subscriptions o where o.user_id=v_account and o.shop_id=p_shop_id and o.type_id=c.id))),
        'selected_type_ids',coalesce((select jsonb_agg(c.id order by c.display_order,c.id)
            from public.shop_notification_catalog c where c.is_active and c.is_visible and (
                (c.id = 'event' and exists (select 1 from public.shop_event_notification_subscriptions e where e.user_id=v_account and e.shop_id=p_shop_id))
                or exists (select 1 from public.shop_operating_notification_subscriptions o where o.user_id=v_account and o.shop_id=p_shop_id and o.type_id=c.id)
            )),'[]'::jsonb)
    ) into v_result from shop_notification_private.catalog_revision r;
    return v_result;
end;
$$;

create function public.save_shop_notification_settings(p_shop_id uuid, p_expected_account_id uuid, p_catalog_revision bigint, p_selected_type_ids text[], p_clear_all boolean)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_account uuid;
begin
    v_account := shop_notification_private.validate_request(p_shop_id, p_expected_account_id);
    if p_catalog_revision is distinct from (select revision from shop_notification_private.catalog_revision) then
        raise sqlstate 'PT409' using message = 'notification_catalog_revision_mismatch';
    end if;
    if p_selected_type_ids is null or exists (
        select 1 from unnest(p_selected_type_ids) selected(id)
        where not exists (select 1 from public.shop_notification_catalog c where c.id=selected.id and c.is_active and c.is_visible)
    ) then raise exception 'notification_type_unavailable'; end if;
    if p_clear_all is null then raise exception 'clear_all_intent_required'; end if;
    delete from public.shop_operating_notification_subscriptions o where user_id=v_account and shop_id=p_shop_id and (p_clear_all or exists(select 1 from public.shop_notification_catalog c where c.id=o.type_id and c.is_active and c.is_visible));
    insert into public.shop_operating_notification_subscriptions(user_id,shop_id,type_id)
        select distinct v_account,p_shop_id,id from unnest(p_selected_type_ids) selected(id) where id <> 'event';
    if 'event' = any(p_selected_type_ids) then
        insert into public.shop_event_notification_subscriptions(user_id,shop_id) values(v_account,p_shop_id) on conflict do nothing;
    elsif p_clear_all or exists(select 1 from public.shop_notification_catalog where id='event' and is_active and is_visible) then
        delete from public.shop_event_notification_subscriptions where user_id=v_account and shop_id=p_shop_id;
    end if;
    return public.fetch_shop_notification_settings(p_shop_id,p_expected_account_id);
end;
$$;

create or replace function public.save_shop_notification_settings(p_shop_id uuid, p_expected_account_id uuid, p_catalog_revision bigint, p_selected_type_ids text[])
returns jsonb language sql security invoker set search_path = '' as $$
    select public.save_shop_notification_settings(p_shop_id,p_expected_account_id,p_catalog_revision,p_selected_type_ids,false);
$$;
revoke all on function public.save_shop_notification_settings(uuid,uuid,bigint,text[],boolean) from public,anon;
grant execute on function public.save_shop_notification_settings(uuid,uuid,bigint,text[],boolean) to authenticated,service_role;

create or replace function public.fetch_subscribed_shop_ids(p_expected_account_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_account uuid := auth.uid(); v_result jsonb;
begin
    if v_account is null then raise exception 'authentication_required'; end if;
    if p_expected_account_id is distinct from v_account then raise exception 'notification_account_mismatch'; end if;
    perform pg_catalog.pg_advisory_xact_lock_shared(2034123456, 1);
    select coalesce(jsonb_agg(s.id order by s.id),'[]'::jsonb) into v_result from public.ramen_shops s
    where s.is_visible and (
        exists (select 1 from public.shop_event_notification_subscriptions e join public.shop_notification_catalog c on c.id='event' and c.is_active where e.shop_id=s.id and e.user_id=v_account)
        or exists (select 1 from public.shop_operating_notification_subscriptions o join public.shop_notification_catalog c on c.id=o.type_id and c.is_active where o.shop_id=s.id and o.user_id=v_account)
    );
    return v_result;
end;
$$;

alter table public.push_registrations add column supported_protocol_version integer not null default 0 check (supported_protocol_version between 0 and 1);

-- Use the existing protected registration implementation (validation, account ownership,
-- abuse limits and FID/token support), rather than duplicating its security contract.
create or replace function public.register_push_registration(registration_identifier text, device_platform text, registration_target_type text)
returns void language plpgsql security definer set search_path = '' as $$
begin
    perform push_registration_private.register_identifier(registration_identifier,device_platform,registration_target_type);
    update public.push_registrations set supported_protocol_version=0 where identifier=registration_identifier and user_id=auth.uid();
end;
$$;
create function public.register_push_registration_protocol(registration_identifier text, device_platform text, registration_target_type text, expected_account_id uuid, supported_protocol_version integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
    if auth.uid() is null or auth.uid() is distinct from expected_account_id then raise exception 'notification_account_mismatch'; end if;
    if supported_protocol_version is null or supported_protocol_version not between 0 and 1 then raise exception 'unsupported_notification_protocol'; end if;
    perform push_registration_private.register_identifier(registration_identifier,device_platform,registration_target_type);
    update public.push_registrations p set supported_protocol_version=register_push_registration_protocol.supported_protocol_version
    where p.identifier=registration_identifier and p.user_id=auth.uid();
end;
$$;
revoke all on function public.register_push_registration_protocol(text,text,text,uuid,integer) from public,anon;
grant execute on function public.register_push_registration_protocol(text,text,text,uuid,integer) to authenticated;
