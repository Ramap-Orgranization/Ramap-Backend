begin;
create function media_private.copy_references() returns table(bucket text,path text,reason text,priority integer)
language sql stable security definer set search_path='' as $$
 with events as materialized (
  select e.*,public.event_is_active_on(e.event_type,e.start_date,e.end_date,(current_timestamp at time zone 'Asia/Seoul')::date) as active from public.shop_events e
 ), menu_urls as materialized (
  select m.image_url as url from public.shop_menu_items m where m.image_url is not null and (m.event_id is null or exists(select 1 from events e where e.id=m.event_id and e.active))
  union all select m.image_url from public.shop_menu_manual_overrides m where m.image_url is not null and m.status='active' and m.action<>'suppress'
 ), menu_locations as (
  select case when url ~ '^https?://' then
   regexp_match(regexp_replace(split_part(split_part(url,'?',1),'#',1),'^https?://[^/]+/',''),'(?:^|/)(shop-profile-images|menu-images|event-images|shop-review-images|profile-avatars|news-report-evidence)/(.+)$')
   else array['menu-images',url] end as location from menu_urls
 )
 select 'event-images',p,case when e.active then 'current_event' else 'ended_event' end,case when e.active then 1 else 9 end from events e cross join lateral unnest(e.image_paths) p
 union all select 'shop-profile-images',instagram_profile_image_path,'current_reference',2 from public.ramen_shops where instagram_profile_image_path is not null
 union all select 'shop-profile-images',image_path,'current_reference',2 from public.external_venues where image_path is not null
 union all select location[1],location[2],'current_reference',2 from menu_locations where location is not null
 union all select 'shop-review-images',p,'current_reference',2 from public.shop_reviews r cross join lateral unnest(r.image_paths) p
 union all select 'profile-avatars',avatar_path,'current_reference',2 from public.public_profiles where avatar_path is not null
 union all select 'shop-review-images',p,'retained_evidence',0 from public.community_reports r cross join lateral unnest(r.review_image_paths_snapshot) p
 union all select 'profile-avatars',profile_avatar_path_snapshot,'retained_evidence',0 from public.community_reports where profile_avatar_path_snapshot is not null
 union all select 'news-report-evidence',attachment_path,'retained_evidence',0 from public.feedback_submissions where attachment_path is not null;
$$;

create or replace function public.media_inventory_v2(p_after text default '',p_limit integer default 500) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 return (
  with source_refs as materialized (
   select distinct on(bucket,path) bucket,path,reason from media_private.copy_references() order by bucket,path,priority
  ), page as materialized (
   select coalesce(o.bucket,s.bucket_id) as bucket,coalesce(o.path,s.name) as path,
    coalesce(o.byte_size,(s.metadata->>'size')::bigint) as byte_size,coalesce(o.content_type,s.metadata->>'mimetype') as content_type,
    o.id,o.checksum,s.updated_at as legacy_updated_at,coalesce(o.bucket,s.bucket_id)||'/'||coalesce(o.path,s.name) as cursor,
    (select coalesce(jsonb_agg(to_jsonb(l)),'[]') from media_private.locations l where l.media_id=o.id and l.verified and not l.deleted) as locations
   from media_private.objects o full join storage.objects s on s.bucket_id=o.bucket and s.name=o.path
   where coalesce(o.bucket,s.bucket_id) in ('shop-profile-images','menu-images','event-images','shop-review-images','profile-avatars','news-report-evidence')
    and (o.id is null or o.state='ready') and coalesce(o.bucket,s.bucket_id)||'/'||coalesce(o.path,s.name)>p_after
   order by coalesce(o.bucket,s.bucket_id)||'/'||coalesce(o.path,s.name) limit least(greatest(p_limit,1),500)
  )
  select coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('migration_reason',coalesce(r.reason,'unreferenced'),
   'migration_needed',coalesce(r.reason in ('current_event','current_reference','retained_evidence'),false)) order by p.cursor),'[]')
  from page p left join source_refs r on r.bucket=p.bucket and r.path=p.path
 );
end;
$$;
revoke all on function media_private.copy_references() from public,anon,authenticated;
commit;
