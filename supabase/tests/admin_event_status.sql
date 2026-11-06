-- Run against an isolated database containing the status RPC and a minimal shop_events fixture.
-- The caller wraps this file in a transaction and rolls it back after verification.
do $$
declare
    ongoing_id uuid := gen_random_uuid();
    expired_id uuid := gen_random_uuid();
    upcoming_id uuid := gen_random_uuid();
    finite_id uuid := gen_random_uuid();
    today date := '2026-10-11';
begin
    insert into public.shop_events (id, start_date, end_date) values
        (ongoing_id, '2026-10-01', null),
        (expired_id, '2026-10-01', '2026-10-10'),
        (upcoming_id, '2026-10-12', '2026-10-13'),
        (finite_id, '2026-10-09', '2026-10-12');

    perform public.merge_shop_event_status_dates(ongoing_id, 'sold_out', 'today', null, today, null, null);
    assert (select sold_out_dates = array[today] from public.shop_events where id = ongoing_id),
        'open-ended event accepts todays sold-out status';

    perform public.merge_shop_event_status_dates(ongoing_id, 'cancelled', 'custom_period', 'test reason', today, today, today + 1);
    assert (select cancelled_dates @> array[today, today + 1] and cardinality(sold_out_dates) = 0 and cancellation_reason = 'test reason' from public.shop_events where id = ongoing_id),
        'custom cancellation works without an end date and clears overlapping sold-out dates';

    begin
        perform public.merge_shop_event_status_dates(ongoing_id, 'cancelled', 'entire_period', 'test reason', today, null, null);
        raise check_violation using message = 'unbounded entire period must be rejected';
    exception when raise_exception then
        assert sqlerrm = 'event end date is required', 'entire period still requires an end date';
    end;

    begin
        perform public.merge_shop_event_status_dates(expired_id, 'sold_out', 'today', null, today, null, null);
        raise check_violation using message = 'expired event must be rejected';
    exception when raise_exception then
        assert sqlerrm = 'active event not found', 'expired event remains protected';
    end;

    begin
        perform public.merge_shop_event_status_dates(upcoming_id, 'sold_out', 'today', null, today, null, null);
        raise check_violation using message = 'future event must be rejected';
    exception when raise_exception then
        assert sqlerrm = 'active event not found', 'future event cannot be marked sold out today';
    end;

    begin
        perform public.merge_shop_event_status_dates(finite_id, 'cancelled', 'custom_period', 'test reason', today, today, today + 2);
        raise check_violation using message = 'out-of-range cancellation must be rejected';
    exception when raise_exception then
        assert sqlerrm = 'custom period is outside event range', 'custom period remains bounded';
    end;

    perform public.merge_shop_event_status_dates(ongoing_id, 'sold_out', 'today', null, today, null, null);
    perform public.merge_shop_event_status_dates(ongoing_id, 'sold_out', 'today', null, today, null, null);
    assert (select sold_out_dates = array[today] and cancelled_dates = array[today + 1] from public.shop_events where id = ongoing_id),
        'repeat saves do not duplicate dates or erase unrelated cancellation dates';

    assert not has_function_privilege('anon', 'public.merge_shop_event_status_dates(uuid,text,text,text,date,date,date)', 'execute')
        and not has_function_privilege('authenticated', 'public.merge_shop_event_status_dates(uuid,text,text,text,date,date,date)', 'execute')
        and has_function_privilege('service_role', 'public.merge_shop_event_status_dates(uuid,text,text,text,date,date,date)', 'execute'),
        'status RPC remains restricted to the service role';
end;
$$;
