-- A revealed public review remains reportable while its author is blocked.
create or replace function public.report_community_content(
    p_target_type text,
    p_target_id uuid,
    p_reason text,
    p_details text default ''
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
    current_user_id uuid;
    target_user_id uuid;
    target_review public.shop_reviews%rowtype;
    target_nickname text;
    target_bio text;
    target_avatar_path text;
begin
    current_user_id := community_private.require_live_user();
    if p_target_type not in ('review', 'user') or p_target_id is null
       or p_reason not in ('spam', 'harassment', 'hate', 'sexual_content', 'violence', 'privacy', 'other')
       or p_details is null or p_details <> btrim(p_details) or char_length(p_details) > 1000
    then
        raise exception 'Invalid report';
    end if;
    if p_target_type = 'review' then
        select * into target_review from public.shop_reviews
        where id = p_target_id and moderation_status = 'published' and is_public;
        if not found or not (
            community_private.can_view_public_profile(target_review.user_id)
            or community_private.can_view_blocked_review_once(target_review.id)
        ) then
            raise exception 'Invalid report target';
        end if;
        target_user_id := target_review.user_id;
        select nickname, bio, avatar_path into target_nickname, target_bio, target_avatar_path
        from public.public_profiles where user_id = target_user_id;
    else
        target_user_id := p_target_id;
        select nickname, bio, avatar_path into target_nickname, target_bio, target_avatar_path
        from public.public_profiles where user_id = target_user_id;
        if target_nickname is null or not (
            community_private.can_view_public_profile(target_user_id)
            or exists (select 1 from public.user_blocks where blocker_id = current_user_id and blocked_id = target_user_id)
        ) then
            raise exception 'Invalid report target';
        end if;
    end if;
    if target_user_id = current_user_id then raise exception 'Invalid report target'; end if;
    insert into public.community_reports(
        reporter_id, target_user_id, review_id, target_type, target_id, reason, details,
        review_body_snapshot, review_image_paths_snapshot, profile_nickname_snapshot, profile_bio_snapshot, profile_avatar_path_snapshot
    ) values (
        current_user_id, target_user_id, target_review.id, p_target_type, p_target_id, p_reason, p_details,
        target_review.body, target_review.image_paths, target_nickname, target_bio, target_avatar_path
    ) on conflict (reporter_id, target_type, target_id) where status = 'pending' do nothing;
end;
$function$;
