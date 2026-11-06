CREATE OR REPLACE FUNCTION public.merge_shop_event_status_dates(p_event_id uuid, p_status text, p_scope text, p_reason text, p_today date, p_start_date date, p_end_date date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    target_dates date[];
    event_start_date date;
    event_end_date date;
begin
    if p_status not in ('cancelled', 'sold_out')
        or p_scope not in ('today', 'entire_period', 'custom_period')
        or (p_status = 'cancelled' and nullif(trim(p_reason), '') is null)
        or (p_status = 'sold_out' and p_scope <> 'today')
        or (p_scope = 'custom_period' and (p_status <> 'cancelled' or p_start_date is null or p_end_date is null or p_start_date > p_end_date)) then
        raise exception 'invalid event status update';
    end if;

    select start_date, end_date
    into event_start_date, event_end_date
    from public.shop_events
    where id = p_event_id
      and start_date <= p_today
      and (end_date is null or end_date >= p_today);

    if event_start_date is null then
        raise exception 'active event not found';
    end if;

    if p_scope = 'entire_period' and event_end_date is null then
        raise exception 'event end date is required';
    end if;

    if p_scope = 'custom_period'
        and (p_start_date < event_start_date or (event_end_date is not null and p_end_date > event_end_date)) then
        raise exception 'custom period is outside event range';
    end if;

    target_dates := case
        when p_scope = 'today' then array[p_today]
        when p_scope = 'custom_period' then array(select generate_series(p_start_date, p_end_date, interval '1 day')::date)
        else array(select generate_series(event_start_date, event_end_date, interval '1 day')::date)
    end;

    update public.shop_events
    set cancelled_dates = case
            when p_status = 'cancelled' then array(select distinct unnest(coalesce(cancelled_dates, '{}') || target_dates))
            when p_status = 'sold_out' then array(select existing_date from unnest(coalesce(cancelled_dates, '{}')) as existing(existing_date) where existing_date <> all(target_dates))
            else cancelled_dates
        end,
        sold_out_dates = case
            when p_status = 'sold_out' then array(select distinct unnest(coalesce(sold_out_dates, '{}') || target_dates))
            when p_status = 'cancelled' then array(select existing_date from unnest(coalesce(sold_out_dates, '{}')) as existing(existing_date) where existing_date <> all(target_dates))
            else sold_out_dates
        end,
        cancellation_reason = case when p_status = 'cancelled' then p_reason else cancellation_reason end
    where id = p_event_id;
end;
$function$;

revoke all on function public.merge_shop_event_status_dates(uuid, text, text, text, date, date, date) from public, anon, authenticated;
grant execute on function public.merge_shop_event_status_dates(uuid, text, text, text, date, date, date) to service_role;
