alter table notification_private.settings add column operating_notice_automatic_enabled boolean not null default false;

create table notification_private.operating_notice_queue (
    notice_id uuid primary key references operating_notice_private.shop_operating_notices(id) on delete cascade,
    created_at timestamptz not null default now(),
    completed_at timestamptz,
    outcome text check(outcome in ('published','skipped')),
    attempts integer not null default 0,
    available_at timestamptz not null default now(),
    last_error text
);
create index operating_notice_queue_pending_idx on notification_private.operating_notice_queue(available_at,created_at) where completed_at is null;
alter table notification_private.operating_notice_queue enable row level security;
revoke all on notification_private.operating_notice_queue from public,anon,authenticated;
grant all on notification_private.operating_notice_queue to service_role;

-- Explicit publications reserve their linkage in the same insert transaction.
create or replace view public.admin_shop_operating_notice_records with (security_invoker=true) as
select id,shop_id,raw_post_id,notice_type,description,notice_date,start_time,end_time,source_url,
       ocr_text,confidence,review_note,created_at,updated_at,end_date,schedule_override,manually_released_at,daily_schedules,announcement_id
from operating_notice_private.shop_operating_notices;
revoke all on public.admin_shop_operating_notice_records from public,anon,authenticated;
grant select,insert,update,delete on public.admin_shop_operating_notice_records to service_role;

create function notification_private.enqueue_operating_notice() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
    if new.announcement_id is null and new.notice_type in ('full_close','early_close','planned_close')
       and exists(select 1 from notification_private.settings where singleton and operating_notice_automatic_enabled) then
        insert into notification_private.operating_notice_queue(notice_id) values(new.id) on conflict do nothing;
    end if;
    return new;
end;
$$;
create trigger enqueue_operating_notice_notification after insert on operating_notice_private.shop_operating_notices
for each row execute function notification_private.enqueue_operating_notice();

create function notification_private.operating_notice_document(p_notice_id uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
    select jsonb_build_object(
        'source',jsonb_build_object('url',n.source_url,'raw_text',n.description,'official_verified',true),
        'facts',jsonb_build_array(jsonb_build_object(
            'id',n.id,'shop_id',n.shop_id,'shop_name',s.name,
            'type_id',case n.notice_type when 'full_close' then 'temporary_closure' when 'early_close' then 'early_closing' when 'planned_close' then 'shortened_hours' end,
            'verified',true,'certainty','confirmed','starts_on',n.notice_date,'ends_on',coalesce(n.end_date,n.notice_date),
            'starts_at',null,'ends_at',case when n.notice_type='full_close' then null else to_char(n.end_time,'HH24:MI') end,
            'time_meaning',case when n.notice_type='full_close' then 'full_day' else 'closing' end,
            'exception_dates','[]'::jsonb,'message',btrim(regexp_replace(n.description,'[[:space:][:cntrl:]]+',' ','g')),
            'context_key','operating-notice-'||n.id::text,'destination',jsonb_build_object('version',1,'action','operating_notices'),
            'registration_type','operating_notice','registration_id',n.id
        )))
    from operating_notice_private.shop_operating_notices n join public.ramen_shops s on s.id=n.shop_id
    where n.id=p_notice_id and n.announcement_id is null and s.is_visible and n.manually_released_at is null
      and coalesce(n.end_date,n.notice_date)>=(current_timestamp at time zone 'Asia/Seoul')::date
      and n.notice_type in ('full_close','early_close','planned_close')
      and (n.notice_type='full_close' or n.end_time is not null)
      and n.start_time is null and n.schedule_override is null and n.daily_schedules='[]'::jsonb;
$$;

create function public.fetch_pending_operating_notice_publications(p_limit integer) returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
    if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_batch_limit'; end if;
    if not exists(select 1 from notification_private.settings where singleton and transport_enabled and operating_notice_automatic_enabled) then return '[]'::jsonb; end if;
    return (select coalesce(jsonb_agg(jsonb_build_object('notice_id',q.notice_id,'document',notification_private.operating_notice_document(q.notice_id)) order by q.created_at),'[]'::jsonb)
        from (select notice_id,created_at from notification_private.operating_notice_queue where completed_at is null and attempts<5 and available_at<=now() order by created_at limit p_limit) q);
end;
$$;

-- The Edge Function validates the exact canonical document and payload before
-- calling this atomic publication transaction. Concurrent edits require a retry.
create function public.publish_operating_notice_notification(p_notice_id uuid,p_document jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare pending notification_private.operating_notice_queue%rowtype; current_document jsonb; publication jsonb; aid uuid; revision integer;
begin
    perform pg_catalog.pg_advisory_xact_lock(2034123457,1);
    if not exists(select 1 from notification_private.settings where singleton and transport_enabled and operating_notice_automatic_enabled) then return jsonb_build_object('disabled',true); end if;
    perform 1 from operating_notice_private.shop_operating_notices where id=p_notice_id for update;
    select * into pending from notification_private.operating_notice_queue where notice_id=p_notice_id for update;
    if not found then return jsonb_build_object('skipped',true); end if;
    if pending.completed_at is not null then return jsonb_build_object('already_processed',true); end if;
    current_document := notification_private.operating_notice_document(p_notice_id);
    if current_document is distinct from p_document then raise exception 'operating_notice_changed'; end if;
    if current_document is null then
        update notification_private.operating_notice_queue set completed_at=now(),outcome='skipped' where notice_id=p_notice_id;
        return jsonb_build_object('skipped',true);
    end if;
    publication := public.notification_publication_command('draft',null,0,p_document,'notice-'||p_notice_id||'-draft');
    aid := (publication->>'announcement_id')::uuid; revision := (publication->>'revision')::integer;
    perform public.link_notification_registration(aid,revision,'operating_notice',p_notice_id,true);
    perform public.notification_publication_command('preview',aid,revision,null,'notice-'||p_notice_id||'-preview');
    perform public.notification_publication_command('publish',aid,revision,null,'notice-'||p_notice_id||'-publish');
    update notification_private.operating_notice_queue set completed_at=now(),outcome='published',last_error=null where notice_id=p_notice_id;
    return jsonb_build_object('published',true,'announcement_id',aid);
end;
$$;

create function public.record_operating_notice_publication_failure(p_notice_id uuid,p_error text) returns void
language sql security invoker set search_path='' as $$
    update notification_private.operating_notice_queue
    set attempts=attempts+1,available_at=now()+interval '1 minute',last_error=left(p_error,200)
    where notice_id=p_notice_id and completed_at is null;
$$;

-- Editing/deleting an automatically published notice cancels unsent old copy.
-- It does not fabricate a correction notification or resend prior history.
create function notification_private.invalidate_automatic_operating_notice() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
    if old.announcement_id is not null and exists(select 1 from notification_private.operating_notice_queue where notice_id=old.id) then
        if tg_op='DELETE' or (to_jsonb(old)-array['updated_at','announcement_id','review_note','ocr_text','confidence'])
            is distinct from (to_jsonb(new)-array['updated_at','announcement_id','review_note','ocr_text','confidence']) then
            perform public.invalidate_notification_registration('operating_notice',old.id);
        end if;
    end if;
    if tg_op='DELETE' then return old; end if;
    return new;
end;
$$;
create trigger invalidate_automatic_operating_notice before update or delete on operating_notice_private.shop_operating_notices
for each row execute function notification_private.invalidate_automatic_operating_notice();

revoke all on function notification_private.enqueue_operating_notice(),notification_private.operating_notice_document(uuid),notification_private.invalidate_automatic_operating_notice() from public,anon,authenticated;
grant execute on function notification_private.enqueue_operating_notice(),notification_private.operating_notice_document(uuid),notification_private.invalidate_automatic_operating_notice() to service_role;
revoke all on function public.fetch_pending_operating_notice_publications(integer),public.publish_operating_notice_notification(uuid,jsonb),public.record_operating_notice_publication_failure(uuid,text) from public,anon,authenticated;
grant execute on function public.fetch_pending_operating_notice_publications(integer),public.publish_operating_notice_notification(uuid,jsonb),public.record_operating_notice_publication_failure(uuid,text) to service_role;
notify pgrst,'reload schema';
