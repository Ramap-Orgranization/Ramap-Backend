begin;

alter table public.profile_follows add column read_at timestamptz;

create or replace function community_private.fetch_my_follow_counts()
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
        'requests', count(*) filter (where f.followed_id = current_user_id and f.status = 'pending'),
        'has_unread_followers', coalesce(bool_or(f.read_at is null) filter (
            where f.followed_id = current_user_id and f.status = 'following'), false),
        'has_unread_requests', coalesce(bool_or(f.read_at is null) filter (
            where f.followed_id = current_user_id and f.status = 'pending'), false)
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

create or replace function community_private.fetch_my_follow_connections(p_list text, p_offset bigint default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare current_user_id uuid;
declare result jsonb;
begin
    current_user_id := community_private.require_live_user();
    if p_list is null or p_list not in ('followers', 'following', 'requests')
       or p_offset is null or p_offset < 0 then
        raise exception 'Invalid follow page' using errcode = '22023';
    end if;
    with page as materialized (
        select jsonb_build_object('user_id', p.user_id, 'nickname', p.nickname, 'avatar_path', p.avatar_path) as profile,
               f.created_at, p.user_id, f.follower_id, f.followed_id
        from public.profile_follows f join public.public_profiles p
          on p.user_id = case when p_list = 'following' then f.followed_id else f.follower_id end
        where (case when p_list = 'following' then f.follower_id else f.followed_id end) = current_user_id
          and f.status = case when p_list = 'requests' then 'pending' else 'following' end
          and p.suspended_at is null
          and not exists (select 1 from public.account_deletion_requests d where d.user_id = p.user_id)
          and not exists (select 1 from public.user_blocks b
              where (b.blocker_id = current_user_id and b.blocked_id = p.user_id)
                 or (b.blocker_id = p.user_id and b.blocked_id = current_user_id))
        order by f.created_at desc, p.user_id desc limit 20 offset p_offset
    ), marked as (
        update public.profile_follows f
        set read_at = now()
        from page
        where p_list in ('followers', 'requests')
          and f.follower_id = page.follower_id
          and f.followed_id = current_user_id
          and f.followed_id = page.followed_id
          and f.created_at = page.created_at
          and f.read_at is null
        returning f.follower_id
    )
    select coalesce(jsonb_agg(page.profile order by page.created_at desc, page.user_id desc), '[]'::jsonb)
    into result from page;
    return result;
end;
$$;

create or replace function public.fetch_my_follow_connections(p_list text, p_offset bigint default 0)
returns jsonb language sql volatile security invoker set search_path = '' as $$
    select community_private.fetch_my_follow_connections(p_list, p_offset);
$$;

revoke all on function community_private.fetch_my_follow_connections(text, bigint) from public, anon;
grant execute on function community_private.fetch_my_follow_connections(text, bigint) to authenticated;
revoke all on function public.fetch_my_follow_connections(text, bigint) from public, anon;
grant execute on function public.fetch_my_follow_connections(text, bigint) to authenticated;

commit;
