begin;
create or replace function media_private.copy_reason(p_bucket text,p_path text) returns text
language plpgsql stable security definer set search_path='' as $$
declare today date := (current_timestamp at time zone 'Asia/Seoul')::date;
declare unused_reason text := 'unreferenced';
begin
 if p_bucket='event-images' then
  if exists(select 1 from public.shop_events e where p_path=any(e.image_paths) and public.event_is_active_on(e.event_type,e.start_date,e.end_date,today)) then return 'current_event'; end if;
  if exists(select 1 from public.shop_events e where p_path=any(e.image_paths)) then unused_reason:='ended_event'; end if;
 elsif p_bucket='shop-profile-images' then
  if exists(select 1 from public.ramen_shops where instagram_profile_image_path=p_path)
   or exists(select 1 from public.external_venues where image_path=p_path) then return 'current_reference'; end if;

 elsif p_bucket='shop-review-images' then
  if exists(select 1 from public.community_reports where p_path=any(review_image_paths_snapshot)) then return 'retained_evidence'; end if;
  if exists(select 1 from public.shop_reviews where p_path=any(image_paths)) then return 'current_reference'; end if;
 elsif p_bucket='profile-avatars' then
  if exists(select 1 from public.community_reports where profile_avatar_path_snapshot=p_path) then return 'retained_evidence'; end if;
  if exists(select 1 from public.public_profiles where avatar_path=p_path) then return 'current_reference'; end if;
 elsif p_bucket='news-report-evidence' then
  if exists(select 1 from public.feedback_submissions where attachment_path=p_path) then return 'retained_evidence'; end if;
 end if;
 if exists(select 1 from public.shop_menu_items m where ((p_bucket='menu-images' and m.image_url=p_path) or right(split_part(split_part(m.image_url,'?',1),'#',1),length('/'||p_bucket||'/'||p_path))='/'||p_bucket||'/'||p_path)
    and (m.event_id is null or exists(select 1 from public.shop_events e where e.id=m.event_id and public.event_is_active_on(e.event_type,e.start_date,e.end_date,today))))
   or exists(select 1 from public.shop_menu_manual_overrides m where m.status='active' and m.action<>'suppress'
    and ((p_bucket='menu-images' and m.image_url=p_path) or right(split_part(split_part(m.image_url,'?',1),'#',1),length('/'||p_bucket||'/'||p_path))='/'||p_bucket||'/'||p_path)) then return 'current_reference'; end if;
 return unused_reason;
end;
$$;
commit;
