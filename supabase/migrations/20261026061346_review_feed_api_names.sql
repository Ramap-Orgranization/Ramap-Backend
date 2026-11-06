-- Add feed names while retaining the deployed community API contracts.
create function public.fetch_review_feed_page(
    p_created_at timestamptz default null,
    p_review_id uuid default null
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
    select public.fetch_community_reviews_page_v2(p_created_at, p_review_id);
$$;

create function public.fetch_popular_review_feed_page(
    p_like_count integer default null,
    p_created_at timestamptz default null,
    p_review_id uuid default null
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
    select public.fetch_community_popular_reviews_page(p_like_count, p_created_at, p_review_id);
$$;

create function public.fetch_blocked_review_feed_once(p_review_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
    select public.fetch_community_blocked_review_once(p_review_id);
$$;

revoke all on function public.fetch_review_feed_page(timestamptz, uuid) from public;
revoke all on function public.fetch_popular_review_feed_page(integer, timestamptz, uuid) from public;
revoke all on function public.fetch_blocked_review_feed_once(uuid) from public, anon;
grant execute on function public.fetch_review_feed_page(timestamptz, uuid) to anon, authenticated, service_role;
grant execute on function public.fetch_popular_review_feed_page(integer, timestamptz, uuid) to anon, authenticated, service_role;
grant execute on function public.fetch_blocked_review_feed_once(uuid) to authenticated, service_role;
