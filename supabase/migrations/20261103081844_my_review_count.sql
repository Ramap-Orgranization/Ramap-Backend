create or replace function public.fetch_my_review_count()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
    owner_id uuid;
begin
    owner_id := community_private.require_live_user();
    return (
        select count(*)::integer
        from public.shop_reviews r
        where r.user_id = owner_id
    );
end;
$function$;

revoke all on function public.fetch_my_review_count() from public, anon;
grant execute on function public.fetch_my_review_count() to authenticated;
