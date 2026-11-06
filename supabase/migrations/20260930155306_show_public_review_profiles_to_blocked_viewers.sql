-- A public review author's profile remains visible to a user blocked by that author.
-- A viewer who blocked the author still sees the blocked-profile state.

create or replace function public.fetch_public_community_profile(p_user_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
    if p_user_id is null then return null; end if;
    if p_user_id = auth.uid() or exists (
        select 1
        from public.public_profiles p
        where p.user_id = p_user_id
          and p.is_public
          and p.suspended_at is null
          and not exists (
              select 1 from public.account_deletion_requests d
              where d.user_id = p.user_id
          )
          and not exists (
              select 1 from public.user_blocks b
              where b.blocker_id = auth.uid() and b.blocked_id = p_user_id
          )
    ) then
        return (select jsonb_build_object(
            'user_id', p.user_id, 'nickname', p.nickname, 'bio', p.bio, 'avatar_path', p.avatar_path
        ) from public.public_profiles p where p.user_id = p_user_id);
    end if;
    return null;
end;
$function$;

create or replace function public.fetch_profile_reviews(p_user_id uuid default null::uuid, p_offset bigint default 0)
returns table(id uuid, shop_id uuid, body text, created_at timestamp with time zone, image_paths text[], user_id uuid, nickname text, avatar_path text, moderation_status text, is_public boolean)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare requested_user_id uuid := coalesce(p_user_id, auth.uid());
begin
    if requested_user_id is null or p_offset is null or p_offset < 0 then raise exception 'Invalid review page'; end if;
    if requested_user_id is distinct from auth.uid()
       and public.fetch_public_community_profile(requested_user_id) is null
    then
        return;
    end if;
    return query
    select r.id, r.shop_id, r.body, r.created_at, r.image_paths, r.user_id,
           p.nickname, p.avatar_path, r.moderation_status, r.is_public
    from public.shop_reviews r join public.public_profiles p on p.user_id = r.user_id
    where r.user_id = requested_user_id
      and (
          requested_user_id = auth.uid()
          or (r.is_public and r.moderation_status = 'published')
      )
    order by r.created_at desc, r.id desc limit 20 offset p_offset;
end;
$function$;
