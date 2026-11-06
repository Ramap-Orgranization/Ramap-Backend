-- Preserve caller privileges while fixing internal validation and concurrency.

ALTER FUNCTION public.normalize_menu_duplicate_key(menu_name text) SET search_path = '';

ALTER FUNCTION public.event_is_active_on(event_type text, start_date date, end_date date, today date) SET search_path = '';

ALTER FUNCTION public.event_is_today_on(event_type text, start_date date, end_date date, today date) SET search_path = '';

ALTER FUNCTION public.update_updated_at_column() SET search_path = '';

CREATE OR REPLACE FUNCTION public.record_shop_menu_validation_observation(p_run_id uuid, p_shop_id uuid, p_menu_fingerprint text, p_source_hash text, p_menu_items jsonb, p_raw_dom text, p_source_url text, p_parser_version text, p_change_summary jsonb DEFAULT '{}'::jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_snapshot public.shop_menu_snapshots%rowtype;
begin
  if p_shop_id is null
     or p_menu_fingerprint is null or p_menu_fingerprint !~ '^[0-9a-f]{64}$'
     or p_source_hash is null or p_source_hash !~ '^[0-9a-f]{64}$'
     or p_menu_items is null or jsonb_typeof(p_menu_items) is distinct from 'array'
     or p_raw_dom is null or length(p_raw_dom) < 100
     or nullif(btrim(p_source_url), '') is null
     or nullif(btrim(p_parser_version), '') is null
     or p_change_summary is null then
    raise exception 'invalid validated menu observation';
  end if;
  if jsonb_array_length(p_menu_items) = 0 then
    raise exception 'invalid validated menu observation';
  end if;

  select * into v_snapshot
  from public.shop_menu_snapshots
  where shop_id = p_shop_id
  order by captured_at desc, id desc
  limit 1
  for update;

  if not found then
    return 'no_snapshot';
  end if;

  if v_snapshot.menu_fingerprint = p_menu_fingerprint then
    return 'unchanged';
  end if;

  insert into public.shop_menu_change_events (
    shop_id, previous_menu_fingerprint, new_menu_fingerprint,
    previous_source_hash, new_source_hash, change_summary, validation_run_id
  ) values (
    p_shop_id, v_snapshot.menu_fingerprint, p_menu_fingerprint,
    v_snapshot.source_hash, p_source_hash, p_change_summary, p_run_id
  );

  insert into public.shop_menu_snapshots (
    shop_id, source_url, parser_version, source_hash,
    raw_dom, menu_items, menu_fingerprint
  ) values (
    p_shop_id, p_source_url, p_parser_version, p_source_hash,
    p_raw_dom, p_menu_items, p_menu_fingerprint
  );

  return 'applied';
end;
$function$;

REVOKE ALL ON FUNCTION public.record_shop_menu_validation_observation(uuid, uuid, text, text, jsonb, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_shop_menu_validation_observation(uuid, uuid, text, text, jsonb, text, text, text, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.track_shop_menu_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    target_shop_id uuid;
begin
    if tg_table_name = 'shop_menu_sections' then
        target_shop_id := coalesce(new.shop_id, old.shop_id);
    else
        select section.shop_id into target_shop_id
        from public.shop_menu_sections section
        where section.id = coalesce(new.section_id, old.section_id);
    end if;

    if target_shop_id is null then
        return coalesce(new, old);
    end if;

    -- The parent is already absent when this trigger runs during ON DELETE CASCADE.
    -- Keep an existing parent alive until the timestamp write has completed.
    perform 1 from public.ramen_shops where id = target_shop_id for key share;
    if not found then
        return coalesce(new, old);
    end if;

    insert into public.shop_menu_update_timestamps (shop_id, updated_at)
    values (target_shop_id, now())
    on conflict (shop_id) do update
    set updated_at = excluded.updated_at;

    return coalesce(new, old);
end;
$function$;

CREATE OR REPLACE FUNCTION public.schedule_event_notification_cron()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    project_url text;
    cron_secret text;
begin
    if coalesce((select auth.jwt() ->> 'role'), '') <> 'service_role' then
        raise exception 'service role required';
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('public.schedule_event_notification_cron', 0)
    );

    select decrypted_secret into project_url
    from vault.decrypted_secrets where name = 'project_url';
    select decrypted_secret into cron_secret
    from vault.decrypted_secrets where name = 'event_notification_cron_secret';

    if project_url is null or cron_secret is null then
        raise exception 'required Vault secrets are missing';
    end if;

    perform cron.unschedule(jobid) from cron.job
    where jobname in ('event-notification-day-before', 'event-notification-event-day');

    perform cron.schedule(
        'event-notification-day-before',
        '0 12 * * *',
        format($job$
            select net.http_post(
                url := %L || '/functions/v1/notify-event-reminders',
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'x-cron-secret', %L
                ),
                body := '{"notification_type":"day_before"}'::jsonb
            );
        $job$, project_url, cron_secret)
    );

    perform cron.schedule(
        'event-notification-event-day',
        '0 0 * * *',
        format($job$
            select net.http_post(
                url := %L || '/functions/v1/notify-event-reminders',
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'x-cron-secret', %L
                ),
                body := '{"notification_type":"event_day"}'::jsonb
            );
        $job$, project_url, cron_secret)
    );
end;
$function$;

-- This compatibility view is read-only. Server writes use ramen_shops.

REVOKE ALL ON TABLE public.shop_waiting_systems FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL (id, shop_id, provider, provider_url) ON TABLE public.shop_waiting_systems FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON TABLE public.shop_waiting_systems TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
