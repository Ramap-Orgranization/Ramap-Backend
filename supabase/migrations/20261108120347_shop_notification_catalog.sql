-- Settings categories are independent from operating-notice registration types.
create schema if not exists shop_notification_private;
revoke all on schema shop_notification_private from public, anon, authenticated;
grant usage on schema shop_notification_private to authenticated, service_role;

create table public.shop_notification_catalog (
    id text primary key check (id ~ '^[a-z][a-z0-9_]{0,63}$'),
    title text not null check (length(btrim(title)) between 1 and 100),
    description text not null default '' check (length(description) <= 1000),
    display_order integer not null,
    is_active boolean not null default true,
    is_visible boolean not null default true
);
alter table public.shop_notification_catalog enable row level security;
revoke all on public.shop_notification_catalog from public, anon, authenticated;
grant select on public.shop_notification_catalog to authenticated;
grant select, insert, update, delete on public.shop_notification_catalog to service_role;
create policy notification_catalog_read on public.shop_notification_catalog for select to authenticated using (true);

create table shop_notification_private.catalog_revision (
    singleton boolean primary key default true check (singleton),
    revision bigint not null default 1
);
insert into shop_notification_private.catalog_revision default values;
revoke all on shop_notification_private.catalog_revision from public, anon, authenticated;
grant select on shop_notification_private.catalog_revision to authenticated;
grant select on shop_notification_private.catalog_revision to service_role;

create table public.shop_operating_notification_subscriptions (
    user_id uuid not null references auth.users(id) on delete cascade,
    shop_id uuid not null references public.ramen_shops(id) on delete cascade,
    type_id text not null references public.shop_notification_catalog(id) on delete cascade check (type_id <> 'event'),
    created_at timestamptz not null default now(),
    primary key (user_id, shop_id, type_id)
);
create index shop_operating_notification_type_idx on public.shop_operating_notification_subscriptions(type_id);
create index shop_operating_notification_shop_idx on public.shop_operating_notification_subscriptions(shop_id);
alter table public.shop_operating_notification_subscriptions enable row level security;
revoke all on public.shop_operating_notification_subscriptions from public, anon, authenticated;
grant select, insert, delete on public.shop_operating_notification_subscriptions to authenticated;
grant all on public.shop_operating_notification_subscriptions to service_role;
create policy notification_selection_owner on public.shop_operating_notification_subscriptions
    for all to authenticated using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

insert into public.shop_notification_catalog(id,title,description,display_order) values
    ('event','이벤트','매장의 이벤트 소식',10),
    ('temporary_closure','임시휴무','매장의 임시휴무 소식',20),
    ('delayed_opening','오픈 지연','매장의 오픈 지연 소식',30),
    ('early_closing','조기 마감','매장의 조기 마감 소식',40),
    ('shortened_hours','단축 영업','매장의 단축 영업 소식',50),
    ('temporary_suspension','영업 일시 중단','매장의 영업 일시 중단 소식',60);

-- Catalog changes take the exclusive counterpart of readers' transaction lock.
create function shop_notification_private.lock_catalog_mutation() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
    -- A transaction may already own a selection lock. Do not block on a
    -- shared-to-exclusive upgrade while another RPC waits for that selection.
    if not pg_catalog.pg_try_advisory_xact_lock(2034123456, 1) then
        raise sqlstate '55P03' using message = 'notification_catalog_busy_retry';
    end if;
    return null;
end;
$$;
create trigger notification_catalog_lock before insert or update or delete on public.shop_notification_catalog
for each statement execute function shop_notification_private.lock_catalog_mutation();

-- The private trigger needs cross-account deletion only for catalog invalidation.
-- It is not a callable Data API endpoint and is never granted to clients.
create function shop_notification_private.catalog_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    if TG_OP = 'UPDATE' and NEW.id <> OLD.id then
        raise exception 'notification_type_id_is_immutable';
    end if;
    if TG_OP = 'DELETE' and OLD.id = 'event' then
        raise exception 'legacy_event_type_cannot_be_deleted';
    end if;
    if TG_OP = 'UPDATE' and (not NEW.is_active or not NEW.is_visible) then
        delete from public.shop_operating_notification_subscriptions where type_id = NEW.id;
    end if;
    update shop_notification_private.catalog_revision set revision = revision + 1;
    return null;
end;
$$;
create trigger notification_catalog_changed after insert or update or delete on public.shop_notification_catalog
for each row execute function shop_notification_private.catalog_changed();

create function shop_notification_private.lock_selection_statement() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
    perform pg_catalog.pg_advisory_xact_lock_shared(2034123456, 1);
    return null;
end;
$$;
create trigger notification_selection_statement_lock before insert or update or delete on public.shop_operating_notification_subscriptions
for each statement execute function shop_notification_private.lock_selection_statement();
create trigger notification_event_statement_lock before insert or update or delete on public.shop_event_notification_subscriptions
for each statement execute function shop_notification_private.lock_selection_statement();

-- Direct table writes and legacy clients use the same user/shop serialization.
create function shop_notification_private.lock_selection_mutation() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare v_account uuid; v_shop uuid;
begin
    if TG_OP = 'DELETE' then
        v_account := OLD.user_id;
        v_shop := OLD.shop_id;
    else
        v_account := NEW.user_id;
        v_shop := NEW.shop_id;
    end if;
    perform pg_catalog.pg_advisory_xact_lock_shared(2034123456, 1);
    -- DELETE/UPDATE may already hold a tuple lock. Never wait here for an
    -- RPC that owns the advisory lock and is waiting for that same tuple.
    if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended(v_account::text || ':' || v_shop::text, 0)) then
        raise sqlstate '55P03' using message = 'notification_selection_busy_retry';
    end if;
    if TG_OP = 'DELETE' then return OLD; end if;
    return NEW;
end;
$$;
create trigger notification_selection_lock before insert or update or delete on public.shop_operating_notification_subscriptions
for each row execute function shop_notification_private.lock_selection_mutation();
create trigger notification_event_selection_lock before insert or update or delete on public.shop_event_notification_subscriptions
for each row execute function shop_notification_private.lock_selection_mutation();

create function shop_notification_private.validate_selection() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
    perform pg_catalog.pg_advisory_xact_lock_shared(2034123456, 1);
    if not exists (select 1 from public.shop_notification_catalog c where c.id = NEW.type_id and c.is_active and c.is_visible)
       or not exists (select 1 from public.ramen_shops s where s.id = NEW.shop_id and s.is_visible) then
        raise exception 'notification_selection_unavailable';
    end if;
    return NEW;
end;
$$;
create trigger notification_selection_validate before insert or update on public.shop_operating_notification_subscriptions
for each row execute function shop_notification_private.validate_selection();

create function shop_notification_private.validate_request(p_shop_id uuid, p_expected_account_id uuid)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_account uuid := auth.uid();
begin
    if v_account is null then raise exception 'authentication_required'; end if;
    if p_expected_account_id is distinct from v_account then raise exception 'notification_account_mismatch'; end if;
    perform pg_catalog.pg_advisory_xact_lock_shared(2034123456, 1);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_account::text || ':' || p_shop_id::text, 0));
    if not exists (select 1 from public.ramen_shops s where s.id = p_shop_id and s.is_visible) then
        raise exception 'notification_shop_unavailable';
    end if;
    return v_account;
end;
$$;

create function public.fetch_shop_notification_settings(p_shop_id uuid, p_expected_account_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_account uuid; v_result jsonb;
begin
    v_account := shop_notification_private.validate_request(p_shop_id, p_expected_account_id);
    select jsonb_build_object(
        'account_id',v_account,'shop_id',p_shop_id,'catalog_revision',r.revision,
        'types',coalesce((select jsonb_agg(to_jsonb(c) order by c.display_order,c.id) from public.shop_notification_catalog c where c.is_active and c.is_visible),'[]'::jsonb),
        'selected_type_ids',coalesce((select jsonb_agg(c.id order by c.display_order,c.id)
            from public.shop_notification_catalog c where c.is_active and c.is_visible and (
                (c.id = 'event' and exists (select 1 from public.shop_event_notification_subscriptions e where e.user_id=v_account and e.shop_id=p_shop_id))
                or exists (select 1 from public.shop_operating_notification_subscriptions o where o.user_id=v_account and o.shop_id=p_shop_id and o.type_id=c.id)
            )),'[]'::jsonb)
    ) into v_result from shop_notification_private.catalog_revision r;
    return v_result;
end;
$$;

create function public.save_shop_notification_settings(p_shop_id uuid, p_expected_account_id uuid, p_catalog_revision bigint, p_selected_type_ids text[])
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
    delete from public.shop_operating_notification_subscriptions where user_id=v_account and shop_id=p_shop_id;
    insert into public.shop_operating_notification_subscriptions(user_id,shop_id,type_id)
        select distinct v_account,p_shop_id,id from unnest(p_selected_type_ids) selected(id) where id <> 'event';
    if 'event' = any(p_selected_type_ids) then
        insert into public.shop_event_notification_subscriptions(user_id,shop_id) values(v_account,p_shop_id) on conflict do nothing;
    else
        delete from public.shop_event_notification_subscriptions where user_id=v_account and shop_id=p_shop_id;
    end if;
    return public.fetch_shop_notification_settings(p_shop_id,p_expected_account_id);
end;
$$;

create function public.clear_shop_notification_settings(p_shop_id uuid, p_expected_account_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_account uuid;
begin
    v_account := shop_notification_private.validate_request(p_shop_id,p_expected_account_id);
    delete from public.shop_operating_notification_subscriptions where user_id=v_account and shop_id=p_shop_id;
    delete from public.shop_event_notification_subscriptions where user_id=v_account and shop_id=p_shop_id;
    return public.fetch_shop_notification_settings(p_shop_id,p_expected_account_id);
end;
$$;

create function public.fetch_subscribed_shop_ids(p_expected_account_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_account uuid := auth.uid(); v_result jsonb;
begin
    if v_account is null then raise exception 'authentication_required'; end if;
    if p_expected_account_id is distinct from v_account then raise exception 'notification_account_mismatch'; end if;
    perform pg_catalog.pg_advisory_xact_lock_shared(2034123456, 1);
    select coalesce(jsonb_agg(s.id order by s.id),'[]'::jsonb) into v_result from public.ramen_shops s
    where s.is_visible and (
        exists (select 1 from public.shop_event_notification_subscriptions e join public.shop_notification_catalog c on c.id='event' and c.is_active and c.is_visible where e.shop_id=s.id and e.user_id=v_account)
        or exists (select 1 from public.shop_operating_notification_subscriptions o join public.shop_notification_catalog c on c.id=o.type_id and c.is_active and c.is_visible where o.shop_id=s.id and o.user_id=v_account)
    );
    return v_result;
end;
$$;

-- Preserve legacy signature and semantics, adding the same serialization lock.
create or replace function public.set_shop_event_notification(shop_id uuid, enabled boolean)
returns void language plpgsql security invoker set search_path = '' as $$
declare current_user_id uuid := auth.uid();
begin
    if current_user_id is null then raise exception 'authentication required'; end if;
    if shop_id is null or enabled is null then raise exception 'shop_id and enabled are required'; end if;
    perform pg_catalog.pg_advisory_xact_lock_shared(2034123456, 1);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(current_user_id::text || ':' || shop_id::text, 0));
    if enabled then
        insert into public.shop_event_notification_subscriptions(user_id,shop_id) values(current_user_id,shop_id) on conflict do nothing;
    else
        delete from public.shop_event_notification_subscriptions e where e.user_id=current_user_id and e.shop_id=set_shop_event_notification.shop_id;
    end if;
end;
$$;

revoke all on all functions in schema shop_notification_private from public, anon, authenticated;
grant execute on function shop_notification_private.validate_request(uuid,uuid) to authenticated, service_role;
revoke all on function public.fetch_shop_notification_settings(uuid,uuid), public.save_shop_notification_settings(uuid,uuid,bigint,text[]), public.clear_shop_notification_settings(uuid,uuid), public.fetch_subscribed_shop_ids(uuid), public.set_shop_event_notification(uuid,boolean) from public, anon;
grant execute on function public.fetch_shop_notification_settings(uuid,uuid), public.save_shop_notification_settings(uuid,uuid,bigint,text[]), public.clear_shop_notification_settings(uuid,uuid), public.fetch_subscribed_shop_ids(uuid), public.set_shop_event_notification(uuid,boolean) to authenticated, service_role;
