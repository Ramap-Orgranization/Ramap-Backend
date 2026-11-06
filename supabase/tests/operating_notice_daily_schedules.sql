begin;
do $$
declare
    closed_day jsonb := '{"date":"2026-10-06","closed":true,"schedule_override":null}';
    regular_day jsonb := '{"date":"2026-10-08","closed":false,"schedule_override":null}';
    explicit_day jsonb := '{"date":"2026-10-08","closed":false,"schedule_override":{"closed":false,"open":"11:00","close":"22:00","close_next_day":false,"label":null,"break_times":[]}}';
begin
    assert public.is_valid_operating_notice_daily_schedules('[]', null, null), 'legacy notices';
    assert public.is_valid_operating_notice_daily_schedules(jsonb_build_array(closed_day, regular_day), '2026-10-01', '2026-10-31'), 'separated dates';
    assert public.is_valid_operating_notice_daily_schedules(jsonb_build_array(explicit_day), '2026-10-01', '2026-10-31'), 'explicit hours';
    assert not public.is_valid_operating_notice_daily_schedules(jsonb_build_array(closed_day, closed_day), '2026-10-01', '2026-10-31'), 'duplicate dates';
    assert not public.is_valid_operating_notice_daily_schedules('[{"date":"2026-02-30","closed":true}]', '2026-02-01', '2026-02-28'), 'impossible date';
    assert not public.is_valid_operating_notice_daily_schedules('[{"date":"2026-11-01","closed":true}]', '2026-10-01', '2026-10-31'), 'outside period';
    assert not public.is_valid_operating_notice_daily_schedules('[{"date":"2026-10-01","closed":"true"}]', '2026-10-01', '2026-10-31'), 'invalid boolean';
    assert not public.is_valid_operating_notice_daily_schedules('[{"date":"2026-10-01"}]', '2026-10-01', '2026-10-31'), 'missing boolean';
    assert not public.is_valid_operating_notice_daily_schedules(jsonb_build_array(explicit_day || '{"closed":true}'::jsonb), '2026-10-01', '2026-10-31'), 'contradictory hours';
    assert not public.is_valid_operating_notice_daily_schedules(jsonb_build_array(jsonb_set(explicit_day, '{schedule_override,open}', '"25:00"')), '2026-10-01', '2026-10-31'), 'invalid hour';
end;
$$;
rollback;
