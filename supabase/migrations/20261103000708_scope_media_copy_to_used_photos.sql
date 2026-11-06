begin;

-- Scope migration by current references, independently from image read permissions.
create function media_private.copy_reason(p_bucket text,p_path text) returns text
language plpgsql stable security definer set search_path='' as $$
declare today date := (current_timestamp at time zone 'Asia/Seoul')::date;
begin
 if exists(select 1 from public.shop_menu_items m where ((p_bucket='menu-images' and m.image_url=p_path) or right(split_part(split_part(m.image_url,'?',1),'#',1),length('/'||p_bucket||'/'||p_path))='/'||p_bucket||'/'||p_path)
    and (m.event_id is null or exists(select 1 from public.shop_events e where e.id=m.event_id and public.event_is_active_on(e.event_type,e.start_date,e.end_date,today))))
   or exists(select 1 from public.shop_menu_manual_overrides m where m.status='active' and m.action<>'suppress'
    and ((p_bucket='menu-images' and m.image_url=p_path) or right(split_part(split_part(m.image_url,'?',1),'#',1),length('/'||p_bucket||'/'||p_path))='/'||p_bucket||'/'||p_path)) then return 'current_reference'; end if;
 if p_bucket='event-images' then
  if exists(select 1 from public.shop_events e where p_path=any(e.image_paths) and public.event_is_active_on(e.event_type,e.start_date,e.end_date,today)) then return 'current_event'; end if;
  if exists(select 1 from public.shop_events e where p_path=any(e.image_paths)) then return 'ended_event'; end if;
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
 return 'unreferenced';
end;
$$;
create function public.media_copy_eligibility(p_bucket text,p_path text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare reason text;
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 reason:=media_private.copy_reason(p_bucket,p_path);
 return jsonb_build_object('needed',reason in ('current_event','current_reference','retained_evidence'),'reason',reason);
end;
$$;

create or replace function public.media_inventory_v2(p_after text default '',p_limit integer default 500) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 return (select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('migration_reason',media_private.copy_reason(i.bucket,i.path),
  'migration_needed',media_private.copy_reason(i.bucket,i.path) in ('current_event','current_reference','retained_evidence'))),'[]') from (
  select coalesce(o.bucket,s.bucket_id) as bucket,coalesce(o.path,s.name) as path,
   coalesce(o.byte_size,(s.metadata->>'size')::bigint) as byte_size,coalesce(o.content_type,s.metadata->>'mimetype') as content_type,
   o.id,o.checksum,s.updated_at as legacy_updated_at,
   coalesce(o.bucket,s.bucket_id)||'/'||coalesce(o.path,s.name) as cursor,
   (select coalesce(jsonb_agg(to_jsonb(l)),'[]') from media_private.locations l where l.media_id=o.id and l.verified and not l.deleted) as locations
  from media_private.objects o full join storage.objects s on s.bucket_id=o.bucket and s.name=o.path
  where coalesce(o.bucket,s.bucket_id) in ('shop-profile-images','menu-images','event-images','shop-review-images','profile-avatars','news-report-evidence')
   and (o.id is null or o.state='ready') and coalesce(o.bucket,s.bucket_id)||'/'||coalesce(o.path,s.name)>p_after
  order by coalesce(o.bucket,s.bucket_id)||'/'||coalesce(o.path,s.name) limit least(greatest(p_limit,1),500)
 ) i);
end;
$$;

revoke all on function media_private.copy_reason(text,text) from public,anon,authenticated;
revoke all on function public.media_copy_eligibility(text,text) from public,anon,authenticated;
grant execute on function public.media_copy_eligibility(text,text) to service_role;
create or replace function public.reserve_media_copy_v2(p_bucket text,p_path text,p_source jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare item media_private.objects; source storage.objects; owner_id uuid;
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_path,0));
 if media_private.copy_reason(p_bucket,p_path) not in ('current_event','current_reference','retained_evidence') then return null; end if;
 select * into item from media_private.objects where bucket=p_bucket and path=p_path for update;
 if found then
  if item.state<>'ready' then raise exception 'Copy identity changed'; end if;
  return item.id;
 end if;
 select * into source from storage.objects where bucket_id=p_bucket and name=p_path for update;
 if not found or source.updated_at is distinct from (p_source->>'updated_at')::timestamptz then raise exception 'Copy source changed'; end if;
 owner_id:=coalesce(source.owner,nullif(source.owner_id,'')::uuid);
 if owner_id is null and p_bucket in ('shop-review-images','profile-avatars') and split_part(p_path,'/',1) ~ '^[0-9a-f-]{36}$' then owner_id:=split_part(p_path,'/',1)::uuid; end if;
 if owner_id is not null and exists(select 1 from public.account_deletion_requests where user_id=owner_id) then raise exception 'Owner is deleting'; end if;
 insert into media_private.objects(bucket,path,owner_id,state,byte_size,content_type)
  values(p_bucket,p_path,owner_id,'ready',(source.metadata->>'size')::bigint,source.metadata->>'mimetype') returning * into item;
 insert into media_private.locations(media_id,provider,bucket,path,verified,source_updated_at)
  values(item.id,'supabase',p_bucket,p_path,true,source.updated_at);
 return item.id;
end;
$$;
commit;
