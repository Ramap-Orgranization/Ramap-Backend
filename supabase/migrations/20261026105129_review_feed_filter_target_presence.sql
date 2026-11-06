-- Extend only the new API; existing clients keep their response shape.
create function feed_private.fetch_filtered_review_feed_page_v2(
    p_filter text,
    p_sort text default 'latest',
    p_like_count integer default null,
    p_created_at timestamptz default null,
    p_review_id uuid default null
)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
    viewer uuid := auth.uid();
    result jsonb;
    has_targets boolean;
begin
    -- Reuse authentication, cursor checks, visibility rules and pagination.
    result := feed_private.fetch_filtered_review_feed_page(
        p_filter, p_sort, p_like_count, p_created_at, p_review_id
    );

    if p_filter = 'saved_shops' then
        select exists (
            select 1 from public.user_shop_bookmarks b
            join public.ramen_shops s on s.id = b.shop_id and s.is_visible
            where b.user_id = viewer
        ) into has_targets;
    else
        -- Match the following list, independently of profile/review publication.
        select exists (
            select 1 from public.profile_follows f
            join public.public_profiles p on p.user_id = f.followed_id
            where f.follower_id = viewer and f.status = 'following'
              and p.suspended_at is null
              and not exists (
                  select 1 from public.account_deletion_requests d where d.user_id = p.user_id
              )
              and not exists (
                  select 1 from public.user_blocks b
                  where (b.blocker_id = viewer and b.blocked_id = p.user_id)
                     or (b.blocker_id = p.user_id and b.blocked_id = viewer)
              )
        ) into has_targets;
    end if;

    return result || jsonb_build_object('has_filter_targets', has_targets);
end;
$$;
revoke all on function feed_private.fetch_filtered_review_feed_page_v2(text, text, integer, timestamptz, uuid) from public, anon;
grant execute on function feed_private.fetch_filtered_review_feed_page_v2(text, text, integer, timestamptz, uuid) to authenticated;

create function public.fetch_filtered_review_feed_page_v2(
    p_filter text,
    p_sort text default 'latest',
    p_like_count integer default null,
    p_created_at timestamptz default null,
    p_review_id uuid default null
)
returns jsonb
language sql
stable security invoker
set search_path = ''
as $$
    select feed_private.fetch_filtered_review_feed_page_v2(p_filter, p_sort, p_like_count, p_created_at, p_review_id);
$$;
revoke all on function public.fetch_filtered_review_feed_page_v2(text, text, integer, timestamptz, uuid) from public, anon;
grant execute on function public.fetch_filtered_review_feed_page_v2(text, text, integer, timestamptz, uuid) to authenticated;
