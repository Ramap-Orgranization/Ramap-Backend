CREATE OR REPLACE FUNCTION public.set_review_like(p_review_id uuid, p_liked boolean)
 RETURNS TABLE(like_count integer, is_liked boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
declare target_user_id uuid;
declare target_shop_id uuid;
declare target_is_public boolean;
declare target_moderation_status text;
begin
    current_user_id := community_private.require_live_user();
    if p_review_id is null or p_liked is null then raise exception 'Invalid review like'; end if;
    select r.user_id, r.shop_id, r.is_public, r.moderation_status
    into target_user_id, target_shop_id, target_is_public, target_moderation_status
    from public.shop_reviews r where r.id = p_review_id for share;
    if not found or not target_is_public
       or target_moderation_status <> 'published'
       or not (case when target_user_id is null then
           exists (select 1 from public.ramen_shops s where s.id = target_shop_id and s.is_visible)
       else community_private.can_view_public_profile(target_user_id) end)
    then
        raise exception 'Invalid review like';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(p_review_id::text || ':' || current_user_id::text, 0));
    if p_liked then
        insert into public.review_likes(review_id, user_id)
        values (p_review_id, current_user_id) on conflict do nothing;
    else
        delete from public.review_likes l
        where l.review_id = p_review_id and l.user_id = current_user_id;
    end if;
    return query select count(*)::integer, exists (
        select 1 from public.review_likes l
        where l.review_id = p_review_id and l.user_id = current_user_id
    ) from public.review_likes l where l.review_id = p_review_id;
end;
$function$;
