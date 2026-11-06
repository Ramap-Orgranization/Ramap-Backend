set local lock_timeout = '5s';
set local statement_timeout = '15s';

-- Public inheritance must be revoked as well as the two client-role grants.
revoke execute on function public.claim_due_shop_operating_statuses(integer)
from public, anon, authenticated;

grant execute on function public.claim_due_shop_operating_statuses(integer)
to service_role;

do $assertions$
begin
    if has_function_privilege('anon', 'public.claim_due_shop_operating_statuses(integer)', 'EXECUTE')
       or has_function_privilege('authenticated', 'public.claim_due_shop_operating_statuses(integer)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.claim_due_shop_operating_statuses(integer)', 'EXECUTE') then
        raise exception 'Operating status claiming must be restricted to the server role';
    end if;
end;
$assertions$;

notify pgrst, 'reload schema';
