begin;

-- Keep the deployed UUID-returning RPCs and their permissions unchanged.
-- The new client consumes these receipts to update loaded lists by review ID.
create function community_private.review_mutation_snapshot(p_review_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'id', r.id,
        'shop_id', r.shop_id,
        'shop_name', s.name,
        'user_id', r.user_id,
        'nickname', coalesce(p.nickname, ''),
        'avatar_path', p.avatar_path,
        'body', r.body,
        'created_at', r.created_at,
        'image_paths', r.image_paths,
        'moderation_status', r.moderation_status,
        'moderation_note', r.moderation_note,
        'is_public', r.is_public,
        'is_blocked', false,
        'author_review_count', (
            select count(*)::integer from public.shop_reviews author_review
            where author_review.user_id = r.user_id
              and author_review.is_public
              and author_review.moderation_status = 'published'
        ),
        'visit_number', (
            select count(*)::integer from public.shop_reviews visit_review
            where visit_review.user_id = r.user_id
              and visit_review.shop_id = r.shop_id
              and visit_review.is_public
              and visit_review.moderation_status = 'published'
              and (visit_review.created_at, visit_review.id) <= (r.created_at, r.id)
        ),
        'like_count', (
            select count(*)::integer from public.review_likes review_like
            where review_like.review_id = r.id
        ),
        'is_liked', false
    )
    from public.shop_reviews r
    join public.ramen_shops s on s.id = r.shop_id
    left join public.public_profiles p on p.user_id = r.user_id
    where r.id = p_review_id and r.user_id = auth.uid();
$$;
revoke all on function community_private.review_mutation_snapshot(uuid) from public, anon, authenticated;

create function community_private.review_owner_counts(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'total_count', count(*)::integer,
        'public_count', count(*) filter (where r.is_public)::integer,
        'private_count', count(*) filter (where not r.is_public)::integer,
        'published_count', count(*) filter (where r.is_public and r.moderation_status = 'published')::integer,
        'profile_is_public', coalesce((
            select p.is_public from public.public_profiles p
            where p.user_id = p_user_id and p.user_id = auth.uid()
        ), false)
    )
    from public.shop_reviews r
    where r.user_id = p_user_id and r.user_id = auth.uid();
$$;
revoke all on function community_private.review_owner_counts(uuid) from public, anon, authenticated;

create function public.fetch_my_review_projection_v2(p_review_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform community_private.require_live_user();
    if p_review_id is null then raise exception 'Invalid review'; end if;
    return community_private.review_mutation_snapshot(p_review_id);
end;
$$;
revoke all on function public.fetch_my_review_projection_v2(uuid) from public, anon;
grant execute on function public.fetch_my_review_projection_v2(uuid) to authenticated;

create function public.submit_shop_review_v2(
    p_shop_id uuid,
    p_body text,
    p_image_paths text[] default '{}'::text[],
    p_is_public boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    owner_id uuid;
    review_id uuid;
    after_snapshot jsonb;
begin
    owner_id := community_private.require_live_user();
    review_id := public.submit_shop_review(p_shop_id, p_body, p_image_paths, p_is_public);
    after_snapshot := community_private.review_mutation_snapshot(review_id);
    return jsonb_build_object(
        'review_id', review_id,
        'user_id', owner_id,
        'shop_id', p_shop_id,
        'before', null,
        'after', after_snapshot,
        'owner_counts', community_private.review_owner_counts(owner_id)
    );
end;
$$;
revoke all on function public.submit_shop_review_v2(uuid, text, text[], boolean) from public, anon;
grant execute on function public.submit_shop_review_v2(uuid, text, text[], boolean) to authenticated;

create function public.update_shop_review_v2(
    p_review_id uuid,
    p_body text,
    p_image_paths text[],
    p_is_public boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    owner_id uuid;
    before_snapshot jsonb;
    after_snapshot jsonb;
begin
    owner_id := community_private.require_current_member();
    perform 1 from public.shop_reviews r
    where r.id = p_review_id and r.user_id = owner_id for update;
    if not found then raise exception 'Invalid review'; end if;
    before_snapshot := community_private.review_mutation_snapshot(p_review_id);
    perform public.update_shop_review(p_review_id, p_body, p_image_paths, p_is_public);
    after_snapshot := community_private.review_mutation_snapshot(p_review_id);
    return jsonb_build_object(
        'review_id', p_review_id,
        'user_id', owner_id,
        'shop_id', before_snapshot -> 'shop_id',
        'before', before_snapshot,
        'after', after_snapshot,
        'owner_counts', community_private.review_owner_counts(owner_id)
    );
end;
$$;
revoke all on function public.update_shop_review_v2(uuid, text, text[], boolean) from public, anon;
grant execute on function public.update_shop_review_v2(uuid, text, text[], boolean) to authenticated;

create function public.delete_shop_review_v2(p_review_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    owner_id uuid;
    before_snapshot jsonb;
begin
    owner_id := community_private.require_current_member();
    perform 1 from public.shop_reviews r
    where r.id = p_review_id and r.user_id = owner_id for update;
    if not found then raise exception 'Invalid review'; end if;
    before_snapshot := community_private.review_mutation_snapshot(p_review_id);
    perform public.delete_shop_review(p_review_id);
    return jsonb_build_object(
        'review_id', p_review_id,
        'user_id', owner_id,
        'shop_id', before_snapshot -> 'shop_id',
        'before', before_snapshot,
        'after', null,
        'owner_counts', community_private.review_owner_counts(owner_id)
    );
end;
$$;
revoke all on function public.delete_shop_review_v2(uuid) from public, anon;
grant execute on function public.delete_shop_review_v2(uuid) to authenticated;

commit;
