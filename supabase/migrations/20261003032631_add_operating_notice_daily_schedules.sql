-- A monthly notice remains one public notice. Only explicitly listed dates override hours.
create or replace function public.is_valid_operating_notice_daily_schedules(
    schedules jsonb, period_start date, period_end date
) returns boolean
language plpgsql immutable security invoker set search_path = ''
as $$
declare
    item jsonb;
    schedule jsonb;
    period jsonb;
    notice_day date;
    seen_dates date[] := '{}';
    time_pattern constant text := '^([01][0-9]|2[0-3]):[0-5][0-9]$';
begin
    if schedules is null or jsonb_typeof(schedules) <> 'array' then return false; end if;
    if jsonb_array_length(schedules) = 0 then return true; end if;
    if jsonb_array_length(schedules) > 31 or period_start is null or period_end is null
       or period_start > period_end or date_trunc('month', period_start::timestamp) <> date_trunc('month', period_end::timestamp)
    then return false; end if;
    for item in select value from jsonb_array_elements(schedules) loop
        if jsonb_typeof(item) <> 'object' or jsonb_typeof(item->'date') is distinct from 'string'
           or (item->>'date') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
           or jsonb_typeof(item->'closed') is distinct from 'boolean' then return false; end if;
        notice_day := (item->>'date')::date;
        if notice_day < period_start or notice_day > period_end or notice_day = any(seen_dates) then return false; end if;
        seen_dates := array_append(seen_dates, notice_day);
        schedule := item->'schedule_override';
        if schedule is null or schedule = 'null'::jsonb then continue; end if;
        if (item->>'closed')::boolean or jsonb_typeof(schedule) <> 'object'
           or schedule->'closed' is distinct from 'false'::jsonb
           or jsonb_typeof(schedule->'open') is distinct from 'string'
           or jsonb_typeof(schedule->'close') is distinct from 'string'
           or (schedule->>'open') !~ time_pattern or (schedule->>'close') !~ time_pattern
           or jsonb_typeof(schedule->'close_next_day') is distinct from 'boolean'
           or jsonb_typeof(schedule->'break_times') is distinct from 'array'
        then return false; end if;
        if (schedule->>'close_next_day')::boolean then
            if (schedule->>'close') > (schedule->>'open') then return false; end if;
        elsif (schedule->>'close') <= (schedule->>'open') then return false;
        end if;
        for period in select value from jsonb_array_elements(schedule->'break_times') loop
            if jsonb_typeof(period->'start') is distinct from 'string'
               or jsonb_typeof(period->'end') is distinct from 'string'
               or (period->>'start') !~ time_pattern or (period->>'end') !~ time_pattern
            then return false; end if;
        end loop;
    end loop;
    return true;
exception when others then
    return false;
end;
$$;

alter table public.shop_operating_notices
    add column daily_schedules jsonb not null default '[]'::jsonb;

alter table public.shop_operating_notices
    add constraint shop_operating_notices_daily_schedules_check check (
        public.is_valid_operating_notice_daily_schedules(daily_schedules, notice_date, end_date)
        and (daily_schedules = '[]'::jsonb or (
            notice_type = 'operating_notice' and schedule_override is null
            and start_time is null and end_time is null
        ))
    );

comment on column public.shop_operating_notices.daily_schedules is
    'Monthly explicit dates: [{date, closed, schedule_override}]. closed=false with no override uses known regular hours; missing hours remain unknown. Empty array preserves legacy notice behavior.';
