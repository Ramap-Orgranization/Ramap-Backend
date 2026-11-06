-- Match Storage access to the public review and review-profile visibility rules.
-- The viewer's own blocks still require the existing one-time reveal path.

create or replace function community_private.can_read_review_image(p_path text)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
    select (
        auth.uid() is not null
        and split_part(p_path, '/', 1) = auth.uid()::text
        and community_private.has_live_user()
    ) or exists (
        select 1 from public.shop_reviews r
        where p_path = any(r.image_paths)
          and r.moderation_status = 'published'
          and r.is_public
          and (
              public.fetch_public_community_profile(r.user_id) is not null
              or community_private.can_view_blocked_review_once(r.id)
          )
    );
$function$;

alter policy "Owners or visible community profiles read avatars"
on storage.objects
using (
    bucket_id = 'profile-avatars'
    and (
        (
            split_part(name, '/', 1) = auth.uid()::text
            and community_private.has_live_user()
        )
        or exists (
            select 1 from public.public_profiles p
            where p.avatar_path = objects.name
              and public.fetch_public_community_profile(p.user_id) is not null
        )
    )
);
