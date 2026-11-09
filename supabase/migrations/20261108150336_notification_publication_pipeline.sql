-- No schedule or transport activation. Sources and review material are service-only.
create schema notification_private;
revoke all on schema notification_private from public,anon,authenticated;
grant usage on schema notification_private to service_role;
create table notification_private.settings (
    singleton boolean primary key default true check(singleton),
    transport_enabled boolean not null default false
);
insert into notification_private.settings default values;
create table notification_private.announcements (
    id uuid primary key default gen_random_uuid(),
    current_revision integer not null default 0,
    created_at timestamptz not null default now()
);
create table notification_private.revisions (
    announcement_id uuid not null references notification_private.announcements(id),
    revision integer not null check(revision>0),
    kind text not null check(kind in ('initial','correction','cancellation')),
    status text not null check(status in ('draft','published','cancelled','invalidated')),
    previewed boolean not null default false,
    published_at timestamptz,
    created_at timestamptz not null default now(),
    primary key(announcement_id,revision)
);
create table notification_private.sources (
    announcement_id uuid not null,
    revision integer not null,
    url text not null,
    raw_text text not null check(octet_length(raw_text)<=100000),
    official_verified boolean not null,
    primary key(announcement_id,revision),
    foreign key(announcement_id,revision) references notification_private.revisions(announcement_id,revision)
);
create table notification_private.facts (
    announcement_id uuid not null,
    revision integer not null,
    id uuid not null,
    shop_id uuid not null references public.ramen_shops(id),
    type_id text not null references public.shop_notification_catalog(id),
    context_key text not null check(length(context_key) between 1 and 120),
    fact jsonb not null,
    primary key(announcement_id,revision,id),
    foreign key(announcement_id,revision) references notification_private.revisions(announcement_id,revision)
);
create index notification_fact_shop_idx on notification_private.facts(shop_id,type_id);
create table notification_private.registrations (
    registration_type text not null check(registration_type in ('event','operating_notice')),
    registration_id uuid not null,
    announcement_id uuid not null references notification_private.announcements(id),
    revision integer not null,
    ready boolean not null default false,
    primary key(registration_type,registration_id),
    foreign key(announcement_id,revision) references notification_private.revisions(announcement_id,revision)
);
alter table public.shop_events add column announcement_id uuid references notification_private.announcements(id);
alter table operating_notice_private.shop_operating_notices add column announcement_id uuid references notification_private.announcements(id);
create index shop_event_announcement_idx on public.shop_events(announcement_id) where announcement_id is not null;
create index shop_notice_announcement_idx on operating_notice_private.shop_operating_notices(announcement_id) where announcement_id is not null;
create table notification_private.deliveries (
    id uuid primary key default gen_random_uuid(),
    announcement_id uuid not null,
    revision integer not null,
    user_id uuid not null references auth.users(id) on delete cascade,
    registration_identifier text not null,
    protocol_version integer not null,
    target_type text not null,
    status text not null default 'pending' check(status in ('pending','claimed','sending','sent','failed','unknown','cancelled')),
    claim_token uuid,
    lease_until timestamptz,
    attempt_count integer not null default 0,
    sent_fact_ids uuid[] not null default '{}',
    provider_id text,
    last_error text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    foreign key(announcement_id,revision) references notification_private.revisions(announcement_id,revision),
    unique(announcement_id,revision,registration_identifier)
);
create index notification_delivery_claim_idx on notification_private.deliveries(status,created_at);
create index notification_delivery_history_idx on notification_private.deliveries(announcement_id,user_id,registration_identifier);
create table notification_private.requests (
    idempotency_key text primary key check(length(idempotency_key) between 1 and 200),
    signature text not null,
    result jsonb not null
);
-- Defense in depth even though this schema is not exposed through the Data API.
do $$ declare item text; begin
    foreach item in array array['settings','announcements','revisions','sources','facts','registrations','deliveries','requests'] loop
        execute format('alter table notification_private.%I enable row level security',item);
        execute format('revoke all on notification_private.%I from public,anon,authenticated',item);
        execute format('grant all on notification_private.%I to service_role',item);
    end loop;
end $$;

create function notification_private.document(p_id uuid,p_revision integer) returns jsonb
language sql stable security invoker set search_path='' as $$
    select jsonb_build_object('announcement_id',r.announcement_id,'revision',r.revision,'status',r.status,'kind',r.kind,
      'source',jsonb_build_object('url',s.url,'raw_text',s.raw_text,'official_verified',s.official_verified),
      'facts',coalesce((select jsonb_agg(f.fact order by f.context_key,f.id) from notification_private.facts f where f.announcement_id=p_id and f.revision=p_revision),'[]'::jsonb))
    from notification_private.revisions r join notification_private.sources s using(announcement_id,revision)
    where r.announcement_id=p_id and r.revision=p_revision;
$$;

create function notification_private.validate_fact(p_fact jsonb) returns void
language plpgsql security invoker set search_path='' as $$
declare start_day date; end_day date; destination jsonb := p_fact->'destination'; exception_day text;
begin
    if jsonb_typeof(p_fact)<>'object' or coalesce(p_fact->>'certainty','') not in ('confirmed','planned','unknown')
       or jsonb_typeof(p_fact->'verified') is distinct from 'boolean'
       or coalesce(p_fact->>'time_meaning','') not in ('full_day','partial_day','opening','last_order','closing','waitlist_end','unspecified')
       or coalesce(length(p_fact->>'shop_name'),0) not between 1 and 150
       or coalesce(length(p_fact->>'message'),0) not between 1 and 500
       or coalesce(p_fact->>'registration_type','') not in ('event','operating_notice','none')
       or coalesce(length(p_fact->>'context_key'),0) not between 1 and 120 then raise exception 'invalid_notification_fact'; end if;
    perform (p_fact->>'id')::uuid; perform (p_fact->>'shop_id')::uuid;
    if p_fact->>'starts_on' is not null then
        if p_fact->>'starts_on' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'invalid_fact_date'; end if;
        start_day := (p_fact->>'starts_on')::date;
    end if;
    if p_fact->>'ends_on' is not null then
        if p_fact->>'ends_on' !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'invalid_fact_date'; end if;
        end_day := (p_fact->>'ends_on')::date;
    end if;
    if end_day < start_day then raise exception 'invalid_fact_date_range'; end if;
    if p_fact->>'starts_at' is not null then
        if p_fact->>'starts_at' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'invalid_fact_time'; end if;
    end if;
    if p_fact->>'ends_at' is not null then
        if p_fact->>'ends_at' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'invalid_fact_time'; end if;
    end if;
    if jsonb_typeof(p_fact->'exception_dates') is distinct from 'array' then raise exception 'invalid_fact_exceptions'; end if;
    for exception_day in select jsonb_array_elements_text(p_fact->'exception_dates') loop
        if exception_day !~ '^\d{4}-\d{2}-\d{2}$' or exception_day::date < start_day or exception_day::date > coalesce(end_day,start_day) then raise exception 'invalid_fact_exception_date'; end if;
    end loop;
    if destination->>'version' is distinct from '1' or coalesce(destination->>'action','') not in ('event_detail','operating_notices','external_url','none') then raise exception 'invalid_notification_destination'; end if;
    if destination->>'action'='external_url' and (coalesce(destination->>'url','') !~ '^https://[A-Za-z0-9.-]+(/|\?|$)' or length(destination->>'url')>2048 or destination->>'url' ~ '[[:space:][:cntrl:]@\\]') then raise exception 'invalid_notification_url'; end if;
    if destination->>'action'='event_detail' then perform (destination->>'event_id')::uuid; end if;
    if p_fact->>'registration_type'<>'none' then perform (p_fact->>'registration_id')::uuid; end if;
    if p_fact->>'type_id'='event' and (p_fact->>'registration_type'<>'event' or destination->>'action'<>'event_detail' or destination->>'event_id' is distinct from p_fact->>'registration_id') then raise exception 'event_fact_requires_registration'; end if;
end;
$$;

-- Evaluate current consent for each fact, never an aggregate user OR followed by
-- unfiltered content. Visibility of a category only controls settings UI.
create function notification_private.eligible_facts(p_id uuid,p_revision integer,p_user uuid,p_protocol integer,p_context text default null)
returns jsonb language sql stable security invoker set search_path='' as $$
    select coalesce(jsonb_agg(f.fact order by f.id),'[]'::jsonb)
    from notification_private.facts f
    join public.ramen_shops s on s.id=f.shop_id and s.is_visible
    join public.shop_notification_catalog c on c.id=f.type_id and c.is_active
    where f.announcement_id=p_id and f.revision=p_revision and (p_context is null or f.context_key=p_context)
      and (p_protocol>=1 or (f.type_id='event' and f.fact->'destination'->>'action'='event_detail'))
      and ((f.type_id='event'
            and exists(select 1 from public.shop_event_notification_subscriptions e join public.ramen_shops subscribed_shop on subscribed_shop.id=e.shop_id and subscribed_shop.is_visible where e.user_id=p_user and (exists(select 1 from public.shop_events event where event.id=(f.fact->>'registration_id')::uuid and event.shop_id=e.shop_id) or exists(select 1 from public.shop_event_participants participant where participant.event_id=(f.fact->>'registration_id')::uuid and participant.shop_id=e.shop_id)))
            and not exists(select 1 from public.user_event_notification_preferences e where e.user_id=p_user and not e.enabled))
        or (f.type_id<>'event' and exists(select 1 from public.shop_operating_notification_subscriptions o where o.user_id=p_user and o.shop_id=f.shop_id and o.type_id=f.type_id)));
$$;

create function notification_private.assert_publishable(p_id uuid,p_revision integer) returns void
language plpgsql security invoker set search_path='' as $$
declare item record; event_shop uuid;
begin
    -- Delivery history is immutable evidence of what a device may have received.
    -- Corrections must explicitly retain each delivered fact's identity and category;
    -- changing category never grants consent to send the replacement category.
    if exists(
        select 1 from notification_private.facts prior
        join notification_private.revisions history on history.announcement_id=prior.announcement_id and history.revision=prior.revision and history.published_at is not null
        where prior.announcement_id=p_id and prior.revision<p_revision
          and exists(select 1 from notification_private.deliveries d where d.announcement_id=p_id and d.revision=prior.revision and d.status in ('sent','unknown') and prior.id=any(d.sent_fact_ids))
          and not exists(select 1 from notification_private.facts current where current.announcement_id=p_id and current.revision=p_revision and current.id=prior.id and current.type_id=prior.type_id)
    ) then raise exception 'explicit_correction_required'; end if;
    if exists(select 1 from notification_private.revisions where announcement_id=p_id and revision=p_revision and kind='cancellation')
       and exists(
           select 1 from notification_private.facts current
           join notification_private.facts prior on prior.announcement_id=current.announcement_id and prior.id=current.id and prior.revision<current.revision
           join notification_private.revisions history on history.announcement_id=prior.announcement_id and history.revision=prior.revision and history.published_at is not null
           where current.announcement_id=p_id and current.revision=p_revision and current.fact->>'message'=prior.fact->>'message'
       ) then raise exception 'explicit_cancellation_message_required'; end if;
    if not exists(select 1 from notification_private.sources where announcement_id=p_id and revision=p_revision and official_verified) then raise exception 'official_source_not_verified'; end if;
    if not exists(select 1 from notification_private.facts where announcement_id=p_id and revision=p_revision) then raise exception 'notification_facts_required'; end if;
    if (select count(distinct context_key) from notification_private.facts where announcement_id=p_id and revision=p_revision)>1 then raise exception 'split_required'; end if;
    if (select count(distinct (fact->>'starts_on',fact->>'ends_on')) from notification_private.facts where announcement_id=p_id and revision=p_revision)>1 and not (select bool_and(fact->>'time_meaning'='full_day' and type_id='temporary_closure') and count(distinct shop_id)=1 and count(distinct substring(fact->>'starts_on',1,7))=1 and bool_and(substring(fact->>'starts_on',1,7)=substring(coalesce(fact->>'ends_on',fact->>'starts_on'),1,7)) from notification_private.facts where announcement_id=p_id and revision=p_revision) then raise exception 'split_required'; end if;
    for item in select * from notification_private.facts where announcement_id=p_id and revision=p_revision loop
        if not (item.fact->>'verified')::boolean or item.fact->>'certainty'='unknown' or item.fact->>'starts_on' is null then raise exception 'unverified_notification_fact'; end if;
        if item.fact->>'registration_type'='none' then continue; end if;
        if not exists(select 1 from notification_private.registrations r where r.announcement_id=p_id and r.revision=p_revision and r.registration_id=(item.fact->>'registration_id')::uuid and r.registration_type=item.fact->>'registration_type' and r.ready) then raise exception 'notification_registration_not_ready'; end if;
        if item.fact->>'registration_type'='event' then
            select shop_id into event_shop from public.shop_events where id=(item.fact->>'registration_id')::uuid and announcement_id=p_id;
            if not found or (event_shop is distinct from item.shop_id and not exists(select 1 from public.shop_event_participants p where p.event_id=(item.fact->>'registration_id')::uuid and p.shop_id=item.shop_id)) then raise exception 'notification_event_shop_mismatch'; end if;
        elsif not exists(select 1 from operating_notice_private.shop_operating_notices where id=(item.fact->>'registration_id')::uuid and shop_id=item.shop_id and announcement_id=p_id) then raise exception 'notification_notice_shop_mismatch'; end if;
    end loop;
end;
$$;

create function public.notification_publication_command(p_command text,p_announcement_id uuid,p_expected_revision integer,p_document jsonb,p_idempotency_key text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare current_version integer; next_version integer; selected_id uuid := p_announcement_id; existing_status text; item jsonb; result jsonb; request_signature text; request_row notification_private.requests%rowtype; next_kind text;
begin
    if p_command not in ('draft','read','preview','publish','correct','cancel') then raise exception 'unknown_publication_command'; end if;
    if p_command<>'read' and coalesce(length(p_idempotency_key),0) not between 1 and 200 then raise exception 'idempotency_key_required'; end if;
    -- Administrative transactions are low volume and serialized, including duplicate
    -- fact/registration detection across publications. Delivery claims remain independent.
    perform pg_catalog.pg_advisory_xact_lock(2034123457,1);
    request_signature := md5(jsonb_build_array(p_command,p_announcement_id,p_expected_revision,p_document)::text);
    if p_command<>'read' then
        select * into request_row from notification_private.requests where idempotency_key=p_idempotency_key;
        if found then
            if request_row.signature<>request_signature then raise exception 'idempotency_key_reused'; end if;
            return request_row.result;
        end if;
    end if;
    if selected_id is null then
        if p_command<>'draft' or coalesce(p_expected_revision,0)<>0 then raise exception 'announcement_required'; end if;
        insert into notification_private.announcements default values returning id into selected_id;
    end if;
    select current_revision into current_version from notification_private.announcements where id=selected_id for update;
    if not found then raise exception 'announcement_not_found'; end if;
    if p_command='read' then return notification_private.document(selected_id,current_version); end if;
    if coalesce(p_expected_revision,0)<>current_version then raise sqlstate 'PT409' using message='publication_revision_mismatch'; end if;
    select status into existing_status from notification_private.revisions where announcement_id=selected_id and revision=current_version;
    if p_command in ('draft','correct','cancel') then
        if p_command='draft' and existing_status='published' then raise exception 'correction_required'; end if;
        if p_command in ('correct','cancel') and current_version=0 then raise exception 'prior_publication_required'; end if;
        if p_document is null or jsonb_typeof(p_document->'facts') is distinct from 'array' or jsonb_array_length(p_document->'facts')>100 then raise exception 'invalid_publication_document'; end if;
        if coalesce(p_document->'source'->>'url','') !~ '^https://[A-Za-z0-9.-]+(/|\?|$)' or length(p_document->'source'->>'url')>2048 or p_document->'source'->>'url' ~ '[[:space:][:cntrl:]@\\]' then raise exception 'invalid_source_url'; end if;
        if jsonb_typeof(p_document->'source'->'official_verified') is distinct from 'boolean' then raise exception 'invalid_source_verification'; end if;
        next_version := current_version+1;
        next_kind := case when p_command='cancel' then 'cancellation' when p_command='correct' or exists(select 1 from notification_private.revisions where announcement_id=selected_id and published_at is not null) then 'correction' else 'initial' end;
        -- Never retry a sending row after correction: its provider outcome can be unknown.
        update notification_private.deliveries set status=case when status='sending' then 'unknown' else 'cancelled' end,updated_at=now()
        where announcement_id=selected_id and status in ('pending','claimed','sending');
        update notification_private.revisions set status='cancelled' where announcement_id=selected_id and revision=current_version;
        insert into notification_private.revisions(announcement_id,revision,kind,status) values(selected_id,next_version,next_kind,'draft');
        insert into notification_private.sources values(selected_id,next_version,p_document->'source'->>'url',coalesce(p_document->'source'->>'raw_text',''),(p_document->'source'->>'official_verified')::boolean);
        for item in select jsonb_array_elements(p_document->'facts') loop
            perform notification_private.validate_fact(item);
            insert into notification_private.facts values(selected_id,next_version,(item->>'id')::uuid,(item->>'shop_id')::uuid,item->>'type_id',item->>'context_key',item);
        end loop;
        -- A correction is a replacement document, never a union of old date ranges.
        update notification_private.announcements set current_revision=next_version where id=selected_id;
        current_version := next_version;
    elsif p_command='preview' then
        if existing_status<>'draft' then raise exception 'publication_not_draft'; end if;
        perform notification_private.assert_publishable(selected_id,current_version);
        update notification_private.revisions set previewed=true where announcement_id=selected_id and revision=current_version;
    elsif p_command='publish' then
        if existing_status='published' then
            result := notification_private.document(selected_id,current_version);
            insert into notification_private.requests values(p_idempotency_key,request_signature,result);
            return result;
        end if;
        if existing_status<>'draft' or not exists(select 1 from notification_private.revisions where announcement_id=selected_id and revision=current_version and previewed) then raise exception 'matching_preview_required'; end if;
        perform notification_private.assert_publishable(selected_id,current_version);
        if exists(select 1 from notification_private.facts mine join notification_private.facts other on (mine.id=other.id or (mine.fact->>'registration_type'<>'none' and mine.fact->>'registration_type'=other.fact->>'registration_type' and mine.fact->>'registration_id'=other.fact->>'registration_id')) join notification_private.revisions r on r.announcement_id=other.announcement_id and r.revision=other.revision and r.published_at is not null where mine.announcement_id=selected_id and mine.revision=current_version and other.announcement_id<>selected_id) then raise exception 'fact_already_published'; end if;
        update notification_private.revisions set status='published',published_at=now() where announcement_id=selected_id and revision=current_version;
        insert into notification_private.deliveries(announcement_id,revision,user_id,registration_identifier,protocol_version,target_type)
        select selected_id,current_version,p.user_id,p.identifier,p.supported_protocol_version,p.target_type from public.push_registrations p
        where jsonb_array_length(notification_private.eligible_facts(selected_id,current_version,p.user_id,p.supported_protocol_version))>0
          and (not exists(select 1 from notification_private.revisions r where r.announcement_id=selected_id and r.revision=current_version and r.kind<>'initial')
            or exists(select 1 from notification_private.deliveries d where d.announcement_id=selected_id and d.revision<current_version and d.user_id=p.user_id and d.registration_identifier=p.identifier and d.status in ('sent','unknown')))
        on conflict do nothing;
    end if;
    result := notification_private.document(selected_id,current_version);
    insert into notification_private.requests values(p_idempotency_key,request_signature,result);
    return result;
end;
$$;

create function public.link_notification_registration(p_announcement_id uuid,p_expected_revision integer,p_registration_type text,p_registration_id uuid,p_ready boolean)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare current_version integer;
begin
    perform pg_catalog.pg_advisory_xact_lock(2034123457,1);
    select current_revision into current_version from notification_private.announcements where id=p_announcement_id for update;
    if current_version is distinct from p_expected_revision then raise sqlstate 'PT409' using message='publication_revision_mismatch'; end if;
    if not exists(select 1 from notification_private.revisions where announcement_id=p_announcement_id and revision=current_version and status='draft') then raise exception 'publication_not_draft'; end if;
    if p_registration_type='event' then
        perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('notification.event-link.'||p_registration_id::text,0));
        if exists(select 1 from public.event_notification_deliveries where event_id=p_registration_id and notification_type='new_event' and status in ('sent','unknown','claimed','sending')) then raise exception 'standalone_event_correction_required'; end if;
        if not exists(select 1 from public.shop_events where id=p_registration_id and (announcement_id is null or announcement_id=p_announcement_id)) then raise exception 'registration_not_found'; end if;
        update public.shop_events set announcement_id=p_announcement_id where id=p_registration_id;
    elsif p_registration_type='operating_notice' then
        if not exists(select 1 from operating_notice_private.shop_operating_notices where id=p_registration_id and (announcement_id is null or announcement_id=p_announcement_id)) then raise exception 'registration_not_found'; end if;
        update operating_notice_private.shop_operating_notices set announcement_id=p_announcement_id where id=p_registration_id;
    else raise exception 'invalid_registration_type'; end if;
    if exists(select 1 from notification_private.registrations where registration_type=p_registration_type and registration_id=p_registration_id and announcement_id<>p_announcement_id) then raise exception 'registration_already_linked'; end if;
    insert into notification_private.registrations values(p_registration_type,p_registration_id,p_announcement_id,current_version,coalesce(p_ready,false))
    on conflict(registration_type,registration_id) do update set revision=excluded.revision,ready=excluded.ready;
    update notification_private.revisions set previewed=false where announcement_id=p_announcement_id and revision=current_version;
    return notification_private.document(p_announcement_id,current_version);
end;
$$;

create function public.invalidate_notification_registration(p_registration_type text,p_registration_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare linked notification_private.registrations%rowtype; current_version integer;
begin
    perform pg_catalog.pg_advisory_xact_lock(2034123457,1);
    select * into linked from notification_private.registrations where registration_type=p_registration_type and registration_id=p_registration_id;
    if not found then return null; end if;
    select current_revision into current_version from notification_private.announcements where id=linked.announcement_id for update;
    update notification_private.registrations set ready=false where registration_type=p_registration_type and registration_id=p_registration_id;
    update notification_private.revisions set status='invalidated',previewed=false where announcement_id=linked.announcement_id and revision=current_version;
    update notification_private.deliveries set status=case when status='sending' then 'unknown' else 'cancelled' end,updated_at=now() where announcement_id=linked.announcement_id and status in ('pending','claimed','sending');
    return notification_private.document(linked.announcement_id,current_version);
end;
$$;

create function notification_private.delivery_payload(p_delivery notification_private.deliveries)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare registration public.push_registrations%rowtype; selected jsonb; publication notification_private.revisions%rowtype; original_url text;
begin
    select * into registration from public.push_registrations where identifier=p_delivery.registration_identifier and user_id=p_delivery.user_id;
    if not found then return null; end if;
    select r.* into publication from notification_private.revisions r join notification_private.announcements a on a.id=r.announcement_id and a.current_revision=r.revision
    where r.announcement_id=p_delivery.announcement_id and r.revision=p_delivery.revision and r.status='published';
    if not found then return null; end if;
    selected := notification_private.eligible_facts(p_delivery.announcement_id,p_delivery.revision,p_delivery.user_id,registration.supported_protocol_version);
    if publication.kind<>'initial' then
        select coalesce(jsonb_agg(f.value),'[]'::jsonb) into selected from jsonb_array_elements(selected) f
        where exists(select 1 from notification_private.deliveries d where d.announcement_id=p_delivery.announcement_id and d.revision<p_delivery.revision and d.user_id=p_delivery.user_id and d.registration_identifier=p_delivery.registration_identifier and d.status in ('sent','unknown') and (f.value->>'id')::uuid=any(d.sent_fact_ids));
    end if;
    if jsonb_array_length(selected)=0 then return null; end if;
    select url into original_url from notification_private.sources where announcement_id=p_delivery.announcement_id and revision=p_delivery.revision;
    return jsonb_build_object('delivery_id',p_delivery.id,'claim_token',p_delivery.claim_token,'announcement_id',p_delivery.announcement_id,'revision',p_delivery.revision,
      'registration_identifier',registration.identifier,'user_id',registration.user_id,'target_type',registration.target_type,'supported_protocol_version',registration.supported_protocol_version,
      'facts',selected,'kind',publication.kind,'source_url',original_url);
end;
$$;

create function public.claim_notification_deliveries(p_limit integer,p_lease_seconds integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item notification_private.deliveries%rowtype; payload jsonb; claimed jsonb := '[]'::jsonb;
begin
    if not exists(select 1 from notification_private.settings where singleton and transport_enabled) then return claimed; end if;
    if p_limit is null or p_limit not between 1 and 100 or p_lease_seconds is null or p_lease_seconds not between 10 and 300 then raise exception 'invalid_delivery_claim'; end if;
    -- Crossing the provider boundary is irreversible. A timed-out sending lease is
    -- unknown, not a pending item: automatic retries could duplicate delivery.
    update notification_private.deliveries set status='unknown',last_error='sending_lease_expired',updated_at=now() where status='sending' and lease_until<clock_timestamp();
    for item in select * from notification_private.deliveries where status='pending' or (status='claimed' and lease_until<clock_timestamp()) order by created_at,id for update skip locked limit p_limit loop
        payload := notification_private.delivery_payload(item);
        if payload is null then
            update notification_private.deliveries set status='cancelled',updated_at=now() where id=item.id;
            continue;
        end if;
        update notification_private.deliveries set status='claimed',claim_token=gen_random_uuid(),lease_until=clock_timestamp()+make_interval(secs=>p_lease_seconds),attempt_count=attempt_count+1,updated_at=now() where id=item.id returning * into item;
        claimed := claimed || jsonb_build_array(notification_private.delivery_payload(item));
    end loop;
    return claimed;
end;
$$;

create function public.prepare_notification_delivery(p_delivery_id uuid,p_claim_token uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item notification_private.deliveries%rowtype; payload jsonb;
begin
    if not exists(select 1 from notification_private.settings where singleton and transport_enabled) then return null; end if;
    select * into item from notification_private.deliveries where id=p_delivery_id and claim_token=p_claim_token and status='claimed' and lease_until>clock_timestamp() for update;
    if not found then return null; end if;
    -- Re-read ownership, protocol, shop visibility, activation, and per-fact consent
    -- immediately before committing the transition across the provider boundary.
    payload := notification_private.delivery_payload(item);
    if payload is null then
        update notification_private.deliveries set status='cancelled',updated_at=now() where id=item.id;
        return null;
    end if;
    update notification_private.deliveries set status='sending',sent_fact_ids=array(select (f->>'id')::uuid from jsonb_array_elements(payload->'facts') f),updated_at=now() where id=item.id;
    return payload;
end;
$$;

create function public.complete_notification_delivery(p_delivery_id uuid,p_claim_token uuid,p_status text,p_provider_id text,p_error text)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
    if p_status not in ('sent','failed','unknown') or p_status is null then raise exception 'invalid_delivery_outcome'; end if;
    update notification_private.deliveries set status=p_status,provider_id=left(p_provider_id,500),last_error=left(p_error,2000),updated_at=now()
    where id=p_delivery_id and claim_token=p_claim_token and status='sending';
    return found;
end;
$$;

-- Private implementations contain unpublished source material and credentials are
-- never returned except to the trusted delivery worker via service-only RPCs.
revoke all on all functions in schema notification_private from public,anon,authenticated;
grant execute on all functions in schema notification_private to service_role;
revoke all on function public.notification_publication_command(text,uuid,integer,jsonb,text),public.link_notification_registration(uuid,integer,text,uuid,boolean),public.invalidate_notification_registration(text,uuid),public.claim_notification_deliveries(integer,integer),public.prepare_notification_delivery(uuid,uuid),public.complete_notification_delivery(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.notification_publication_command(text,uuid,integer,jsonb,text),public.link_notification_registration(uuid,integer,text,uuid,boolean),public.invalidate_notification_registration(text,uuid),public.claim_notification_deliveries(integer,integer),public.prepare_notification_delivery(uuid,uuid),public.complete_notification_delivery(uuid,uuid,text,text,text) to service_role;

-- Re-reading in the webhook is necessary but not sufficient: linking can race
-- between that read and its legacy claim. Serialize ONLY new-event claims with
-- linking; retain the established reminder/retry behavior verbatim below.
create or replace function public.claim_event_notification_delivery(delivery_event_id uuid,delivery_user_id uuid,delivery_registration_identifier text,delivery_notification_type text)
returns boolean language plpgsql security definer set search_path='' as $$
declare affected_rows integer := 0;
begin
    if delivery_notification_type not in ('new_event','day_before','event_day') then raise exception 'invalid notification type'; end if;
    if delivery_notification_type='new_event' then
        perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('notification.event-link.'||delivery_event_id::text,0));
        if exists(select 1 from public.shop_events where id=delivery_event_id and announcement_id is not null) then return false; end if;
    end if;
    insert into public.event_notification_deliveries(event_id,user_id,registration_identifier,notification_type,status)
    values(delivery_event_id,delivery_user_id,delivery_registration_identifier,delivery_notification_type,'claimed') on conflict do nothing;
    get diagnostics affected_rows = row_count;
    if affected_rows>0 then return true; end if;
    update public.event_notification_deliveries set status='claimed',attempt_count=attempt_count+1,last_error=null,claimed_at=now(),updated_at=now()
    where event_id=delivery_event_id and user_id=delivery_user_id and registration_identifier=delivery_registration_identifier and notification_type=delivery_notification_type and status='failed' and attempt_count<2;
    get diagnostics affected_rows = row_count;
    return affected_rows>0;
end;
$$;
revoke all on function public.claim_event_notification_delivery(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.claim_event_notification_delivery(uuid,uuid,text,text) to service_role;
