begin;
-- Preserve cloud files and historical locations; retire only runtime selection.
create function media_private.assert_media_retirement_safe() returns void
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from media_private.objects where upload_provider='gcs' and state in ('pending','deleting'))
  or exists(select 1 from media_private.cleanup where provider='gcs') then raise exception 'Finish existing photo uploads and cleanup before retiring storage'; end if;
 if exists(select 1 from media_private.objects o join media_private.locations l on l.media_id=o.id
  where o.state='ready' and l.provider='gcs' and not l.deleted and not exists(
    select 1 from media_private.locations available where available.media_id=o.id and available.verified and not available.deleted
    and (available.provider='r2' or (available.provider='supabase' and exists(select 1 from storage.objects s where s.bucket_id=o.bucket and s.name=o.path)))))
 then raise exception 'Copy photos to supported storage before retiring the old location'; end if;
end;
$$;
select media_private.assert_media_retirement_safe();
update media_private.locations set deleted=true where provider='gcs';
update media_private.objects set upload_provider='r2',required_providers=array_remove(required_providers,'gcs');
alter table media_private.objects alter column upload_provider set default 'r2';
alter table media_private.objects drop constraint objects_upload_provider_check;
alter table media_private.objects add constraint objects_upload_provider_check check(upload_provider='r2');
update media_private.settings set read_enabled=false,write_enabled=false where singleton;

create or replace function media_private.upload_policy(p_r2 boolean,p_bucket text) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('provider','r2','required_providers',to_jsonb(
  case when legacy_required then array['supabase']::text[] else array[]::text[] end))
 from media_private.settings where singleton;
$$;

create or replace function media_private.prepare_upload(p_bucket text,p_path text,p_content_type text,p_byte_size bigint,p_r2 boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare user_id uuid := community_private.require_live_user();
declare item media_private.objects;
declare rules storage.buckets;
declare policy jsonb := media_private.upload_policy(p_r2,p_bucket);
begin
    select * into rules from storage.buckets where id=p_bucket;
    if p_bucket not in ('shop-review-images','profile-avatars','news-report-evidence','shop-profile-images','menu-images','event-images')
      or rules.id is null or p_byte_size is null or p_byte_size<=0
      or (rules.file_size_limit is not null and p_byte_size>rules.file_size_limit)
      or (rules.allowed_mime_types is not null and not p_content_type=any(rules.allowed_mime_types))
      or p_content_type not in ('image/jpeg','image/png','image/webp') then raise exception 'Invalid media upload'; end if;
    if p_bucket in ('shop-review-images','profile-avatars') then
        if p_path !~ ('^'||user_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png)$')
          or (p_bucket='shop-review-images' and not community_private.has_review_upload_permission()) then raise insufficient_privilege; end if;
    elsif not media_private.is_administrator() then raise insufficient_privilege;
    end if;
    if p_bucket='news-report-evidence' and (not community_private.can_upload_news_report_evidence(user_id::text)
      or p_path !~ '^[0-9a-f-]{36}[.](jpg|png)$') then raise insufficient_privilege; end if;
    if not p_r2 or not (select r2_write_enabled from media_private.settings) then return jsonb_build_object('provider','supabase'); end if;
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    select * into item from media_private.objects where bucket=p_bucket and path=p_path for update;
    if found then
        if item.owner_id is distinct from user_id or item.content_type is distinct from p_content_type or item.byte_size is distinct from p_byte_size
          or item.state not in ('pending','ready') then raise exception 'Media identity conflict'; end if;
        if item.state='pending' and item.upload_expires_at<=now() then raise exception 'Upload expired'; end if;
    else
        if exists(select 1 from storage.objects where bucket_id=p_bucket and name=p_path) then raise exception 'Media already exists'; end if;
        if (select count(*) from media_private.objects where owner_id=user_id and created_at>now()-interval '1 minute')>=30 then raise sqlstate 'PT429' using message='Media upload rate limited'; end if;
        insert into media_private.objects(bucket,path,owner_id,content_type,byte_size,upload_provider,required_providers)
        values(p_bucket,p_path,user_id,p_content_type,p_byte_size,policy->>'provider',array(select jsonb_array_elements_text(policy->'required_providers'))) returning * into item;
    end if;
    return to_jsonb(item)||jsonb_build_object('provider',item.upload_provider,'legacy_required','supabase'=any(item.required_providers));
end;
$$;

create or replace function media_private.prepare_service_upload(p_bucket text,p_path text,p_content_type text,p_byte_size bigint,p_r2 boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
declare rules storage.buckets;
declare policy jsonb := media_private.upload_policy(p_r2,p_bucket);
begin
    if auth.role() is distinct from 'service_role' or p_bucket not in ('shop-profile-images','menu-images','event-images') then raise insufficient_privilege; end if;
    select * into rules from storage.buckets where id=p_bucket;
    if rules.id is null or p_byte_size is null or p_byte_size<=0 or (rules.file_size_limit is not null and p_byte_size>rules.file_size_limit)
       or p_content_type not in ('image/jpeg','image/png','image/webp') then raise exception 'Invalid media upload'; end if;
    if not p_r2 or not (select r2_write_enabled from media_private.settings) then return jsonb_build_object('provider','supabase'); end if;
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    insert into media_private.objects(bucket,path,content_type,byte_size,upload_provider,required_providers) values(p_bucket,p_path,p_content_type,p_byte_size,policy->>'provider',array(select jsonb_array_elements_text(policy->'required_providers'))) on conflict(bucket,path) do nothing;
    select * into item from media_private.objects where bucket=p_bucket and path=p_path;
    if item.state not in ('pending','ready') or item.content_type is distinct from p_content_type or item.byte_size is distinct from p_byte_size then raise exception 'Media identity conflict'; end if;
    return to_jsonb(item)||jsonb_build_object('provider',item.upload_provider,'legacy_required','supabase'=any(item.required_providers));
end;
$$;

create or replace function media_private.resolve_locations(p_images jsonb,p_r2 boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare input jsonb; item media_private.objects; location media_private.locations; legacy storage.objects; result jsonb:='[]';
begin
 if jsonb_typeof(p_images) is distinct from 'array' or jsonb_array_length(p_images)>64 then raise exception 'Invalid media batch'; end if;
 for input in select value from jsonb_array_elements(p_images) loop
  select * into item from media_private.objects where bucket=input->>'bucket' and path=input->>'path';
  if found then
   if item.state<>'ready' or not media_private.can_read(item.bucket,item.path,item.owner_id) then continue; end if;
   select l.* into location from media_private.locations l cross join media_private.settings s
    where l.media_id=item.id and l.verified and not l.deleted and
      (l.provider='supabase' or (l.provider='r2' and p_r2 and s.r2_read_enabled))
    order by case l.provider when 'r2' then 0 else 1 end limit 1;
   if not found then continue; end if;
   result:=result||jsonb_build_array(jsonb_build_object('bucket',item.bucket,'path',item.path,'provider',location.provider,
    'physical_bucket',location.bucket,'object_key',location.path,'generation',location.generation,'etag',location.etag));
  else
   select * into legacy from storage.objects where bucket_id=input->>'bucket' and name=input->>'path';
   if not found or not media_private.can_read(legacy.bucket_id,legacy.name,coalesce(legacy.owner,nullif(legacy.owner_id,'')::uuid)) then continue; end if;
   result:=result||jsonb_build_array(jsonb_build_object('bucket',legacy.bucket_id,'path',legacy.name,'provider','supabase','physical_bucket',legacy.bucket_id,'object_key',legacy.name));
  end if;
 end loop;
 return result;
end;
$$;

create or replace function public.register_media_targets_v2(p_id uuid,p_targets jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare item media_private.objects; target jsonb; existing media_private.locations;
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 select * into item from media_private.objects where id=p_id for update;
 if not found or item.state<>'pending' or item.upload_expires_at<=now() then raise exception 'Pending upload unavailable'; end if;
 if jsonb_typeof(p_targets) is distinct from 'array' then raise exception 'Invalid targets'; end if;
 if 'supabase'=any(item.required_providers) then
  insert into media_private.locations(media_id,provider,bucket,path) values(p_id,'supabase',item.bucket,item.path) on conflict do nothing;
 end if;
 for target in select value from jsonb_array_elements(p_targets) loop
  if target->>'provider' is distinct from 'r2' or coalesce(target->>'bucket','')='' then raise exception 'Invalid target'; end if;
  select * into existing from media_private.locations where media_id=p_id and provider=target->>'provider';
  if found and (existing.bucket is distinct from target->>'bucket' or existing.path is distinct from item.bucket||'/'||item.path or existing.deleted) then raise exception 'Media location conflict'; end if;
  insert into media_private.locations(media_id,provider,bucket,path)
   values(p_id,target->>'provider',target->>'bucket',item.bucket||'/'||item.path) on conflict do nothing;
  if target->>'provider'=item.upload_provider then
   if coalesce(target->>'pending_bucket','')='' then raise exception 'Invalid pending target'; end if;
   insert into media_private.cleanup(media_id,provider,bucket,path,not_before)
    values(p_id,item.upload_provider,target->>'pending_bucket','pending/'||p_id::text,item.upload_expires_at+interval '7 minutes') on conflict do nothing;
  end if;
 end loop;
 if not exists(select 1 from media_private.locations where media_id=p_id and provider=item.upload_provider and not deleted) then raise exception 'Upload target missing'; end if;
end;
$$;

create or replace function public.complete_media_upload_v2(p_id uuid,p_locations jsonb,p_size bigint,p_type text,p_checksum text) returns void
language plpgsql security definer set search_path='' as $$
declare item media_private.objects; location jsonb; provider_name text;
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 select * into item from media_private.objects where id=p_id;
 if not found then raise exception 'Unknown media'; end if;
 if item.owner_id is not null then
  perform 1 from auth.users where id=item.owner_id for key share;
  if not found or exists(select 1 from public.account_deletion_requests where user_id=item.owner_id)
    or exists(select 1 from public.public_profiles where user_id=item.owner_id and suspended_at is not null) then raise insufficient_privilege; end if;
 elsif item.bucket not in ('shop-profile-images','menu-images','event-images') then raise insufficient_privilege; end if;
 perform pg_advisory_xact_lock(hashtextextended(item.path,0));
 select * into item from media_private.objects where id=p_id for update;
 if item.state='ready' and item.checksum=p_checksum then return; end if;
 if item.state<>'pending' or item.upload_expires_at<=now() or item.byte_size is distinct from p_size or item.content_type is distinct from p_type
  or p_checksum is null or p_checksum !~ '^[0-9a-f]{64}$' or jsonb_typeof(p_locations) is distinct from 'array' then raise exception 'Invalid media completion'; end if;
 foreach provider_name in array array[item.upload_provider]||item.required_providers loop
  if provider_name='supabase' then
   if not exists(select 1 from storage.objects where bucket_id=item.bucket and name=item.path) then raise exception 'Legacy mirror missing'; end if;
   insert into media_private.locations(media_id,provider,bucket,path,verified) values(p_id,'supabase',item.bucket,item.path,true)
    on conflict(media_id,provider) do update set verified=true where not media_private.locations.deleted;
  else
   select value into location from jsonb_array_elements(p_locations) where value->>'provider'=provider_name;
   if provider_name<>'r2' or location is null or coalesce(location->>'etag','')='' then raise exception 'Required mirror missing'; end if;
   update media_private.locations set verified=true,generation=null,etag=location->>'etag'
    where media_id=p_id and provider=provider_name and not deleted and bucket=location->>'bucket'
      and path=location->>'path' and path=item.bucket||'/'||item.path;
   if not found then raise exception 'Media target mismatch'; end if;
  end if;
 end loop;
 update media_private.objects set state='ready',checksum=p_checksum,finalizing_until=null where id=p_id;
end;
$$;

create or replace function public.configure_r2_media(p_read boolean,p_write boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 update media_private.settings set r2_read_enabled=p_read,r2_write_enabled=p_write where singleton;
end;
$$;
create or replace function public.configure_media_storage(p_read boolean,p_write boolean,p_legacy boolean default true) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 if p_read or p_write then raise exception 'Use configure_r2_media'; end if;
 update media_private.settings set read_enabled=false,write_enabled=false,legacy_required=p_legacy where singleton;
end;
$$;

create or replace function public.account_has_external_media(p_user_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 return exists(select 1 from media_private.objects o where o.owner_id=p_user_id and
  (o.state in ('pending','deleting') or exists(select 1 from media_private.locations l where l.media_id=o.id and l.provider<>'supabase' and not l.deleted)
   or exists(select 1 from media_private.cleanup q where q.media_id=o.id)));
end;
$$;

create or replace function public.register_media_copy_target_v2(p_id uuid,p_provider text,p_bucket text) returns void
language plpgsql security definer set search_path='' as $$
declare item media_private.objects;
begin
 if auth.role() is distinct from 'service_role' or p_provider is distinct from 'r2' then raise insufficient_privilege; end if;
 select * into item from media_private.objects where id=p_id for update;
 if not found or item.state<>'ready' then raise exception 'Copy identity changed'; end if;
 if item.owner_id is not null and exists(select 1 from public.account_deletion_requests where user_id=item.owner_id) then raise exception 'Owner is deleting'; end if;
 insert into media_private.locations(media_id,provider,bucket,path) values(p_id,p_provider,p_bucket,item.bucket||'/'||item.path) on conflict do nothing;
 if not exists(select 1 from media_private.locations where media_id=p_id and provider=p_provider and bucket=p_bucket and path=item.bucket||'/'||item.path and not deleted) then raise exception 'Copy target changed'; end if;
 update media_private.objects set finalizing_until=now()+interval '5 minutes' where id=p_id;
end;
$$;

create or replace function public.record_media_copy_v2(p_id uuid,p_source jsonb,p_destination jsonb,p_checksum text,p_size bigint,p_type text) returns void
language plpgsql security definer set search_path='' as $$
declare item media_private.objects;
begin
 if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
 select * into item from media_private.objects where id=p_id;
 perform pg_advisory_xact_lock(hashtextextended(item.path,0));
 select * into item from media_private.objects where id=p_id for update;
 if not found or item.state<>'ready' or item.byte_size is distinct from p_size or item.content_type is distinct from p_type
  or p_checksum is null or p_checksum !~ '^[0-9a-f]{64}$' or (item.checksum is not null and item.checksum<>p_checksum)
  or (item.owner_id is not null and exists(select 1 from public.account_deletion_requests where user_id=item.owner_id)) then raise exception 'Copy identity changed'; end if;
 if p_source->>'provider'='supabase' then
  if not exists(select 1 from storage.objects where bucket_id=item.bucket and name=item.path and updated_at=(p_source->>'updated_at')::timestamptz) then raise exception 'Copy source changed'; end if;
 elsif not exists(select 1 from media_private.locations where media_id=p_id and provider=p_source->>'provider' and bucket=p_source->>'bucket' and path=p_source->>'path'
  and generation is not distinct from p_source->>'generation' and etag is not distinct from p_source->>'etag' and verified and not deleted) then raise exception 'Copy source changed'; end if;
 if p_destination->>'provider' is distinct from 'r2' or coalesce(p_destination->>'etag','')='' then raise exception 'Invalid destination'; end if;
 update media_private.locations set verified=true,generation=null,etag=p_destination->>'etag'
  where media_id=p_id and provider=p_destination->>'provider' and bucket=p_destination->>'bucket' and path=p_destination->>'path' and not deleted;
 if not found then raise exception 'Copy target changed'; end if;
 update media_private.objects set checksum=p_checksum,finalizing_until=null where id=p_id;
end;
$$;

-- Obsolete privileged writers are not exposed; migration history remains reproducible.
revoke all on function public.register_media_upload_target(uuid,text,text),public.complete_media_upload(uuid,text,text,text,bigint,text,text),public.record_media_copy(text,text,text,text,text,text,bigint,timestamptz),public.media_inventory(text,integer) from public,anon,authenticated,service_role;
revoke all on all functions in schema media_private from public,anon,authenticated;
commit;
