begin;

create function community_private.fetch_my_follow_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    current_user_id uuid;
    result jsonb;
begin
    current_user_id := community_private.require_live_user();
    select jsonb_build_object(
        'followers', count(*) filter (where f.followed_id = current_user_id and f.status = 'following'),
        'following', count(*) filter (where f.follower_id = current_user_id and f.status = 'following'),
        'requests', count(*) filter (where f.followed_id = current_user_id and f.status = 'pending')
    ) into result
    from public.profile_follows f
    join public.public_profiles p on p.user_id =
        case when f.followed_id = current_user_id then f.follower_id else f.followed_id end
    where (f.follower_id = current_user_id or f.followed_id = current_user_id)
      and p.suspended_at is null
      and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id)
      and not exists (
          select 1 from public.user_blocks b
          where (b.blocker_id = current_user_id and b.blocked_id = p.user_id)
             or (b.blocker_id = p.user_id and b.blocked_id = current_user_id)
      );
    return result;
end;
$$;

create function public.fetch_my_follow_counts()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
    select community_private.fetch_my_follow_counts();
$$;

revoke all on function community_private.fetch_my_follow_counts() from public, anon;
revoke all on function public.fetch_my_follow_counts() from public, anon;
grant execute on function community_private.fetch_my_follow_counts() to authenticated;
grant execute on function public.fetch_my_follow_counts() to authenticated;

commit;
