-- A viewer who blocks an author may reveal one public review even when the author also blocks the viewer.
-- The shop review list already returns a masked card for this case.

create or replace function community_private.can_view_blocked_review_once(p_review_id uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
    select auth.uid() is not null and exists (
        select 1
        from public.shop_reviews r
        join public.public_profiles p on p.user_id = r.user_id
        join public.user_blocks b on b.blocker_id = auth.uid() and b.blocked_id = r.user_id
        where r.id = p_review_id
          and r.is_public
          and r.moderation_status = 'published'
          and p.is_public
          and p.suspended_at is null
          and not exists (
              select 1 from public.account_deletion_requests d where d.user_id = r.user_id
          )
    );
$function$;
