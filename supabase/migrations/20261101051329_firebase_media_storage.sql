begin;

create schema media_private;
revoke all on schema media_private from public;
grant usage on schema media_private to anon, authenticated, service_role;

create table media_private.settings (
    singleton boolean primary key default true check (singleton),
    read_enabled boolean not null default false,
    write_enabled boolean not null default false,
    legacy_required boolean not null default true
);
insert into media_private.settings default values;

create table media_private.objects (
    id uuid primary key default gen_random_uuid(),
    bucket text not null references storage.buckets(id),
    path text not null,
    owner_id uuid,
    state text not null default 'pending' check (state in ('pending','ready','deleting','deleted')),
    content_type text,
    byte_size bigint check (byte_size > 0),
    checksum text check (checksum ~ '^[0-9a-f]{64}$'),
    upload_expires_at timestamptz not null default now() + interval '10 minutes',
    created_at timestamptz not null default now(),
    unique (bucket,path),
    check (bucket in ('shop-review-images','profile-avatars','news-report-evidence','shop-profile-images','menu-images','event-images')),
    check (path <> '' and length(path) <= 512 and path !~ '(^/|\.\.|[?%#\\\\[:cntrl:]])')
);
create index media_objects_owner on media_private.objects(owner_id);
create index media_objects_pending on media_private.objects(upload_expires_at) where state = 'pending';

create table media_private.locations (
    media_id uuid not null references media_private.objects(id),
    provider text not null check (provider in ('supabase','gcs')),
    bucket text not null,
    path text not null,
    generation text,
    source_updated_at timestamptz,
    verified boolean not null default false,
    deleted boolean not null default false,
    primary key (media_id,provider)
);
create table media_private.cleanup (
    id bigint generated always as identity primary key,
    media_id uuid not null references media_private.objects(id),
    provider text not null check (provider in ('supabase','gcs')),
    bucket text not null,
    path text not null,
    generation text,
    not_before timestamptz not null default now(),
    lease_until timestamptz,
    attempts integer not null default 0,
    unique (media_id,provider,bucket,path)
);
alter table media_private.settings enable row level security;
alter table media_private.objects enable row level security;
alter table media_private.locations enable row level security;
alter table media_private.cleanup enable row level security;
revoke all on all tables in schema media_private from public,anon,authenticated;

create function media_private.is_administrator() returns boolean
language sql stable security definer set search_path = '' as $$
    select community_private.has_live_user() and exists (
        select 1 from community_private.news_report_evidence_administrators where user_id=auth.uid()
    );
$$;

create function media_private.can_read(p_bucket text,p_path text,p_owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
    select case p_bucket
      when 'shop-review-images' then community_private.can_read_review_image(p_path)
      when 'profile-avatars' then
        (split_part(p_path,'/',1)=auth.uid()::text and community_private.has_live_user())
        or exists (select 1 from public.public_profiles p where p.avatar_path=p_path and public.fetch_public_community_profile(p.user_id) is not null)
        or community_private.can_read_follow_header_avatar(p_path)
        or community_private.can_read_blocked_user_avatar(p_path)
      when 'news-report-evidence' then community_private.can_read_news_report_evidence(p_owner::text)
      else p_bucket in ('shop-profile-images','menu-images','event-images')
    end;
$$;

create function media_private.lock_available(p_bucket text,p_path text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
declare legacy_id uuid;
begin
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    select * into item from media_private.objects where bucket=p_bucket and path=p_path for update;
    if found then
        if item.state='ready' and exists(select 1 from media_private.locations where media_id=item.id and verified and not deleted) then return item.id; end if;
        return null;
    end if;
    select id into legacy_id from storage.objects where bucket_id=p_bucket and name=p_path for update;
    return legacy_id;
end;
$$;

create function public.resolve_media_locations(p_images jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare input jsonb;
declare item media_private.objects;
declare location media_private.locations;
declare legacy storage.objects;
declare result jsonb := '[]';
declare source text;
begin
    if jsonb_typeof(p_images) is distinct from 'array' or jsonb_array_length(p_images)>64 then raise exception 'Invalid media batch'; end if;
    for input in select value from jsonb_array_elements(p_images) loop
        select * into item from media_private.objects where bucket=input->>'bucket' and path=input->>'path';
        if found then
            if item.state <> 'ready' or not media_private.can_read(item.bucket,item.path,item.owner_id) then continue; end if;
            select l.* into location from media_private.locations l
            where l.media_id=item.id and l.verified and not l.deleted
              and (l.provider='supabase' or (select read_enabled from media_private.settings))
            order by (l.provider='gcs') desc limit 1;
            if not found then continue; end if;
            result := result || jsonb_build_array(jsonb_build_object('bucket',item.bucket,'path',item.path,'provider',location.provider,
                'physical_bucket',location.bucket,'object_key',location.path,'generation',location.generation));
        else
            select * into legacy from storage.objects where bucket_id=input->>'bucket' and name=input->>'path';
            if not found or not media_private.can_read(legacy.bucket_id,legacy.name,coalesce(legacy.owner,legacy.owner_id::uuid)) then continue; end if;
            result := result || jsonb_build_array(jsonb_build_object('bucket',legacy.bucket_id,'path',legacy.name,'provider','supabase',
                'physical_bucket',legacy.bucket_id,'object_key',legacy.name,'generation',legacy.updated_at::text));
        end if;
    end loop;
    return result;
end;
$$;

create function public.prepare_media_upload(p_bucket text,p_path text,p_content_type text,p_byte_size bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare user_id uuid := community_private.require_live_user();
declare item media_private.objects;
declare rules storage.buckets;
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
    if not (select write_enabled from media_private.settings) then return jsonb_build_object('provider','supabase'); end if;
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    select * into item from media_private.objects where bucket=p_bucket and path=p_path for update;
    if found then
        if item.owner_id is distinct from user_id or item.content_type is distinct from p_content_type or item.byte_size is distinct from p_byte_size
          or item.state not in ('pending','ready') then raise exception 'Media identity conflict'; end if;
        if item.state='pending' and item.upload_expires_at<=now() then raise exception 'Upload expired'; end if;
    else
        if exists(select 1 from storage.objects where bucket_id=p_bucket and name=p_path) then raise exception 'Media already exists'; end if;
        if (select count(*) from media_private.objects where owner_id=user_id and created_at>now()-interval '1 minute')>=30 then raise sqlstate 'PT429' using message='Media upload rate limited'; end if;
        insert into media_private.objects(bucket,path,owner_id,content_type,byte_size)
        values(p_bucket,p_path,user_id,p_content_type,p_byte_size) returning * into item;
    end if;
    return to_jsonb(item)||jsonb_build_object('provider','gcs','legacy_required',(select legacy_required from media_private.settings));
end;
$$;

create function public.fetch_media_upload(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare user_id uuid := community_private.require_live_user();
declare item media_private.objects;
begin
    select * into item from media_private.objects where id=p_id and owner_id=user_id;
    if not found or item.state not in ('pending','ready') or (item.state='pending' and item.upload_expires_at<=now()) then raise insufficient_privilege; end if;
    return to_jsonb(item)||jsonb_build_object('legacy_required',(select legacy_required from media_private.settings));
end;
$$;

create function public.complete_media_upload(p_id uuid,p_bucket text,p_key text,p_generation text,p_size bigint,p_type text,p_checksum text) returns void
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    select * into item from media_private.objects where id=p_id;
    if not found then raise exception 'Unknown media'; end if;
    if item.owner_id is not null then
        perform 1 from auth.users where id=item.owner_id for key share;
        if not found or exists(select 1 from public.account_deletion_requests where user_id=item.owner_id)
           or exists(select 1 from public.public_profiles where user_id=item.owner_id and suspended_at is not null) then raise insufficient_privilege; end if;
    elsif item.bucket not in ('shop-profile-images','menu-images','event-images') then raise insufficient_privilege;
    end if;
    perform pg_advisory_xact_lock(hashtextextended(item.path,0));
    select * into item from media_private.objects where id=p_id for update;
    if item.state='ready' then
        if exists(select 1 from media_private.locations where media_id=p_id and provider='gcs' and generation=p_generation and verified and not deleted) then return; end if;
        raise exception 'Media completion conflict';
    end if;
    if item.state<>'pending' or item.upload_expires_at<=now() or item.byte_size is distinct from p_size or item.content_type is distinct from p_type
       or p_generation is null or p_checksum !~ '^[0-9a-f]{64}$' or p_key is distinct from item.bucket||'/'||item.path then raise exception 'Invalid media completion'; end if;
    if (select legacy_required from media_private.settings) and not exists(select 1 from storage.objects where bucket_id=item.bucket and name=item.path) then raise exception 'Legacy mirror missing'; end if;
    insert into media_private.locations(media_id,provider,bucket,path,generation,verified)
    values(p_id,'gcs',p_bucket,p_key,p_generation,true)
    on conflict(media_id,provider) do update set generation=excluded.generation,verified=true
      where media_private.locations.bucket=excluded.bucket and media_private.locations.path=excluded.path and not media_private.locations.deleted;
    if not found then raise exception 'Media location conflict'; end if;
    update media_private.locations set source_updated_at=(select updated_at from storage.objects where bucket_id=item.bucket and name=item.path)
    where media_id=p_id and provider='gcs';
    if exists(select 1 from storage.objects where bucket_id=item.bucket and name=item.path) then
        insert into media_private.locations(media_id,provider,bucket,path,verified) values(p_id,'supabase',item.bucket,item.path,true);
    end if;
    update media_private.objects set state='ready',checksum=p_checksum where id=p_id;
end;
$$;

create function media_private.queue_delete(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
begin
    select * into item from media_private.objects where id=p_id;
    perform pg_advisory_xact_lock(hashtextextended(item.path,0));
    update media_private.objects set state='deleting' where id=p_id and state<>'deleted';
    insert into media_private.cleanup(media_id,provider,bucket,path,generation)
    select media_id,provider,bucket,path,generation from media_private.locations where media_id=p_id and not deleted
    on conflict(media_id,provider,bucket,path) do update set not_before=least(media_private.cleanup.not_before,now());
end;
$$;

create function public.delete_media_object(p_bucket text,p_path text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare user_id uuid := community_private.require_live_user();
declare item media_private.objects;
begin
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    select * into item from media_private.objects where bucket=p_bucket and path=p_path for update;
    if not found then return null; end if;
    if item.owner_id is distinct from user_id and not media_private.is_administrator() then raise insufficient_privilege; end if;
    if p_bucket='shop-review-images' and not community_private.can_delete_review_image(p_path) then raise insufficient_privilege; end if;
    if p_bucket='profile-avatars' and not community_private.can_delete_profile_avatar(p_path) then raise insufficient_privilege; end if;
    if p_bucket='news-report-evidence' and not community_private.can_delete_news_report_evidence(p_path,item.owner_id::text) then raise insufficient_privilege; end if;
    perform media_private.queue_delete(item.id);
    return item.id;
end;
$$;

create function public.prepare_account_media_cleanup(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
begin
    if auth.role() is distinct from 'service_role' or not exists(select 1 from public.account_deletion_requests where user_id=p_user_id) then raise insufficient_privilege; end if;
    for item in select * from media_private.objects where owner_id=p_user_id and state<>'deleted' order by path loop
        perform media_private.queue_delete(item.id);
    end loop;
end;
$$;

create function public.claim_media_cleanup(p_id uuid default null,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
declare result jsonb;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    for item in select * from media_private.objects where state='pending' and upload_expires_at<now() order by path limit 100 loop
        perform media_private.queue_delete(item.id);
    end loop;
    with selected as (
        select id from media_private.cleanup where not_before<=now() and (lease_until is null or lease_until<now())
          and (p_id is null or media_id=p_id) order by id for update skip locked limit least(greatest(p_limit,1),100)
    ), leased as (
        update media_private.cleanup q set lease_until=now()+interval '5 minutes',attempts=attempts+1
        from selected where q.id=selected.id returning q.*
    ) select coalesce(jsonb_agg(to_jsonb(leased)),'[]') into result from leased;
    return result;
end;
$$;

create function public.finish_media_cleanup(p_id bigint,p_success boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare job media_private.cleanup;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    select * into job from media_private.cleanup where id=p_id for update;
    if not found then return; end if;
    if not p_success then
        update media_private.cleanup set lease_until=null,not_before=now()+interval '5 minutes' where id=p_id;
        return;
    end if;
    update media_private.locations set deleted=true where media_id=job.media_id and provider=job.provider and bucket=job.bucket and path=job.path;
    delete from media_private.cleanup where id=p_id;
    update media_private.objects o set state='deleted' where o.id=job.media_id and o.state='deleting'
      and not exists(select 1 from media_private.locations where media_id=o.id and not deleted);
end;
$$;

create function public.media_uploads_for_cleanup() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'bucket',bucket,'path',path,'state',state,'expires_at',upload_expires_at)),'[]')
       from (select * from media_private.objects where state in ('pending','deleting','deleted') and upload_expires_at<now() order by upload_expires_at limit 100) o);
end;
$$;

-- Called only by the trusted copy tool, after byte-for-byte verification.
create function public.record_media_copy(p_bucket text,p_path text,p_physical_bucket text,p_key text,p_generation text,p_checksum text,p_size bigint,p_source_updated_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare source storage.objects;
declare item media_private.objects;
declare source_owner uuid;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    select * into source from storage.objects where bucket_id=p_bucket and name=p_path for update;
    if not found or (source.metadata->>'size')::bigint is distinct from p_size or source.updated_at is distinct from p_source_updated_at then raise exception 'Copy source changed'; end if;
    if p_checksum !~ '^[0-9a-f]{64}$' or p_generation is null or p_key is distinct from p_bucket||'/'||p_path then raise exception 'Invalid verified copy'; end if;
    source_owner := coalesce(source.owner,nullif(source.owner_id,'')::uuid);
    if source_owner is null and p_bucket in ('shop-review-images','profile-avatars') and split_part(p_path,'/',1) ~ '^[0-9a-f-]{36}$' then source_owner := split_part(p_path,'/',1)::uuid; end if;
    if source_owner is not null and exists(select 1 from public.account_deletion_requests where user_id=source_owner) then raise exception 'Owner is deleting'; end if;
    insert into media_private.objects(bucket,path,owner_id,state,byte_size,content_type,checksum)
    values(p_bucket,p_path,source_owner,'ready',p_size,source.metadata->>'mimetype',p_checksum)
    on conflict(bucket,path) do nothing;
    select * into item from media_private.objects where bucket=p_bucket and path=p_path for update;
    if item.state<>'ready' or item.checksum is distinct from p_checksum then raise exception 'Copy identity changed'; end if;
    insert into media_private.locations(media_id,provider,bucket,path,verified) values(item.id,'supabase',p_bucket,p_path,true)
    on conflict(media_id,provider) do nothing;
    insert into media_private.locations(media_id,provider,bucket,path,generation,verified,source_updated_at) values(item.id,'gcs',p_physical_bucket,p_key,p_generation,true,source.updated_at)
    on conflict(media_id,provider) do update set bucket=excluded.bucket,path=excluded.path,generation=excluded.generation,verified=true,source_updated_at=excluded.source_updated_at
      where not media_private.locations.deleted;
end;
$$;

create function public.configure_media_storage(p_read boolean,p_write boolean,p_legacy boolean default true) returns void
language plpgsql security definer set search_path = '' as $$
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    update media_private.settings set read_enabled=p_read,write_enabled=p_write,legacy_required=p_legacy;
end;
$$;

revoke all on all functions in schema media_private from public;
revoke all on function public.resolve_media_locations(jsonb),public.prepare_media_upload(text,text,text,bigint),public.fetch_media_upload(uuid),public.delete_media_object(text,text) from public;
grant execute on function public.resolve_media_locations(jsonb) to anon,authenticated,service_role;
grant execute on function public.prepare_media_upload(text,text,text,bigint),public.fetch_media_upload(uuid),public.delete_media_object(text,text) to authenticated;
revoke all on function public.complete_media_upload(uuid,text,text,text,bigint,text,text),public.prepare_account_media_cleanup(uuid),public.claim_media_cleanup(uuid,integer),public.finish_media_cleanup(bigint,boolean),public.media_uploads_for_cleanup(),public.record_media_copy(text,text,text,text,text,text,bigint,timestamptz),public.configure_media_storage(boolean,boolean,boolean) from public,anon,authenticated;
grant execute on function public.complete_media_upload(uuid,text,text,text,bigint,text,text),public.prepare_account_media_cleanup(uuid),public.claim_media_cleanup(uuid,integer),public.finish_media_cleanup(bigint,boolean),public.media_uploads_for_cleanup(),public.record_media_copy(text,text,text,text,text,text,bigint,timestamptz),public.configure_media_storage(boolean,boolean,boolean) to service_role;

CREATE OR REPLACE FUNCTION public.submit_shop_review(p_shop_id uuid, p_body text, p_image_paths text[] DEFAULT '{}'::text[], p_is_public boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
declare review_id uuid;
declare image_path text;
declare image_object_id uuid;
declare canonical_payload text;
begin
    current_user_id := community_private.require_live_user();
    if p_shop_id is null
       or p_body is null or p_body <> btrim(p_body) or char_length(p_body) not between 5 and 100
       or p_is_public is null
       or p_image_paths is null or cardinality(p_image_paths) > 3
       or coalesce(array_ndims(p_image_paths), 1) <> 1
       or cardinality(p_image_paths) <> (select count(distinct path) from unnest(p_image_paths) path)
       or not public.shop_review_image_paths_belong_to_user(p_image_paths, current_user_id)
       or not exists (select 1 from public.ramen_shops where id = p_shop_id)
    then
        raise exception 'Invalid review';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ramap.review-submit.' || current_user_id::text, 0));
    for image_path in
        select path from unnest(p_image_paths) path order by path
    loop
        perform pg_advisory_xact_lock(hashtextextended(image_path, 0));
        image_object_id := media_private.lock_available('shop-review-images',image_path);
        if image_object_id is null then raise exception 'Review image not found'; end if;
    end loop;
    canonical_payload := pg_catalog.jsonb_build_object('shop_id', p_shop_id, 'body', p_body, 'image_paths', p_image_paths, 'is_public', p_is_public)::text;
    review_id := review_submission_private.reserve_submission(canonical_payload);
    if review_id is not null then return review_id; end if;
    if exists (
        select 1 from public.shop_reviews where image_paths && p_image_paths
    ) then
        raise exception 'Review image already submitted';
    end if;
    perform account_profile_private.fetch_or_create_my_profile(current_user_id);
    insert into public.shop_reviews(shop_id, user_id, body, image_paths, moderation_status, is_public)
    values (p_shop_id, current_user_id, p_body, p_image_paths, 'published', p_is_public) returning id into review_id;
    perform review_submission_private.remember_submission(canonical_payload, review_id);
    return review_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.update_shop_review(p_review_id uuid, p_body text, p_image_paths text[], p_is_public boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid;
declare image_path text;
declare image_object_id uuid;
begin
    current_user_id := community_private.require_current_member();
    if p_review_id is null
       or p_body is null or p_body <> btrim(p_body) or char_length(p_body) not between 5 and 100
       or p_is_public is null
       or p_image_paths is null or cardinality(p_image_paths) > 3
       or coalesce(array_ndims(p_image_paths), 1) <> 1
       or cardinality(p_image_paths) <> (select count(distinct path) from unnest(p_image_paths) path)
       or not public.shop_review_image_paths_belong_to_user(p_image_paths, current_user_id)
    then
        raise exception 'Invalid review';
    end if;
    perform 1 from public.shop_reviews r
    where r.id = p_review_id and r.user_id = current_user_id for update;
    if not found then raise exception 'Invalid review'; end if;
    for image_path in select path from unnest(p_image_paths) path order by path loop
        perform pg_advisory_xact_lock(hashtextextended(image_path, 0));
        image_object_id := media_private.lock_available('shop-review-images',image_path);
        if image_object_id is null then raise exception 'Review image not found'; end if;
    end loop;
    if exists (
        select 1 from public.shop_reviews r
        where r.id <> p_review_id and r.image_paths && p_image_paths
    ) then
        raise exception 'Review image already submitted';
    end if;
    update public.shop_reviews
    set body = p_body, image_paths = p_image_paths, is_public = p_is_public
    where id = p_review_id;
    return p_review_id;
end;
$function$;


CREATE OR REPLACE FUNCTION account_profile_private.update_my_profile(p_user_id uuid, p_nickname text, p_avatar_path text DEFAULT NULL::text, p_remove_photo boolean DEFAULT false, p_bio text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare profile public.public_profiles;
declare today date := account_profile_private.kst_profile_change_date(current_timestamp);
declare changes account_profile_private.profile_daily_change_counts;
declare nickname_changed boolean;
declare bio_changed boolean;
begin
    if auth.uid() is null or p_user_id is distinct from auth.uid() then
        raise exception 'Authentication required or mismatched profile owner' using errcode = '42501';
    end if;
    if p_nickname is null or p_nickname !~ '^[A-Za-z0-9가-힣_]{2,10}$'
        or p_remove_photo is null or (p_remove_photo and p_avatar_path is not null) then
        raise exception 'Invalid profile update';
    end if;
    perform account_profile_private.fetch_or_create_my_profile(p_user_id);
    select * into strict profile from public.public_profiles where user_id = p_user_id for update;
    if profile.suspended_at is not null then
        raise exception 'Account is suspended' using errcode = '42501';
    end if;
    if p_avatar_path is not null and (
        p_avatar_path !~ ('^' || p_user_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png)$')
        or media_private.lock_available('profile-avatars',p_avatar_path) is null
    ) then
        raise exception 'Invalid profile avatar';
    end if;

    nickname_changed := p_nickname is distinct from profile.nickname;
    bio_changed := p_bio is not null and p_bio is distinct from profile.bio;
    if nickname_changed or bio_changed then
        insert into account_profile_private.profile_daily_change_counts(user_id, change_date)
        values (p_user_id, today)
        on conflict (user_id, change_date) do nothing;
        select * into strict changes
        from account_profile_private.profile_daily_change_counts
        where user_id = p_user_id and change_date = today
        for update;
        if nickname_changed and changes.nickname_changes >= 2 then
            raise sqlstate 'PT429' using message = 'PROFILE_NICKNAME_DAILY_LIMIT';
        end if;
        if bio_changed and changes.bio_changes >= 2 then
            raise sqlstate 'PT429' using message = 'PROFILE_BIO_DAILY_LIMIT';
        end if;
        update account_profile_private.profile_daily_change_counts
        set nickname_changes = nickname_changes + case when nickname_changed then 1 else 0 end,
            bio_changes = bio_changes + case when bio_changed then 1 else 0 end
        where user_id = p_user_id and change_date = today;
    end if;

    update public.public_profiles
    set nickname = p_nickname,
        bio = coalesce(p_bio, bio),
        avatar_path = case when p_remove_photo then null else coalesce(p_avatar_path, avatar_path) end
    where user_id = p_user_id;
    return account_profile_private.fetch_or_create_my_profile(p_user_id);
end;
$function$;


CREATE OR REPLACE FUNCTION public.delete_current_user()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_user_id uuid := auth.uid();
declare locked_user_id uuid;
begin
    if current_user_id is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    select id into locked_user_id from auth.users where id = current_user_id for update;
    if locked_user_id is null then
        raise exception 'Account is unavailable' using errcode = '42501';
    end if;
    perform public.begin_current_user_deletion();
    if exists (
        select 1 from storage.objects o
        where (o.bucket_id in ('shop-review-images', 'profile-avatars') and o.name like current_user_id::text || '/%')
           or o.owner = current_user_id
           or o.owner_id = current_user_id::text
    ) then
        raise exception 'Account files must be deleted with delete-account Edge Function' using errcode = '55000';
    end if;
    if exists(select 1 from media_private.objects o join media_private.locations l on l.media_id=o.id where o.owner_id=current_user_id and not l.deleted) then
        raise exception 'Media files must be deleted with delete-account' using errcode='55000';
    end if;
    delete from auth.users where id = current_user_id;
    if not found then
        raise exception 'Account is unavailable' using errcode = '42501';
    end if;
end;
$function$;


create function public.register_media_upload_target(p_id uuid,p_pending_bucket text,p_final_bucket text) returns void
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    select * into item from media_private.objects where id=p_id and state='pending';
    if not found then raise exception 'Pending upload unavailable'; end if;
    insert into media_private.cleanup(media_id,provider,bucket,path,not_before)
    values(p_id,'gcs',p_pending_bucket,'pending/'||p_id::text,item.upload_expires_at+interval '1 minute')
    on conflict(media_id,provider,bucket,path) do nothing;
    insert into media_private.locations(media_id,provider,bucket,path)
    values(p_id,'gcs',p_final_bucket,item.bucket||'/'||item.path)
    on conflict(media_id,provider) do nothing;
end;
$$;
revoke all on function public.register_media_upload_target(uuid,text,text) from public,anon,authenticated;
grant execute on function public.register_media_upload_target(uuid,text,text) to service_role;

create function public.fetch_service_media(p_id uuid default null,p_bucket text default null,p_path text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
declare legacy storage.objects;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    select * into item from media_private.objects where (p_id is not null and id=p_id) or (p_id is null and bucket=p_bucket and path=p_path);
    if found then return to_jsonb(item)||jsonb_build_object('legacy_required',(select legacy_required from media_private.settings),
      'locations',(select coalesce(jsonb_agg(to_jsonb(l)),'[]') from media_private.locations l where media_id=item.id and not deleted)); end if;
    select * into legacy from storage.objects where bucket_id=p_bucket and name=p_path;
    if not found then return null; end if;
    return jsonb_build_object('bucket',legacy.bucket_id,'path',legacy.name,'state','ready','locations',
      jsonb_build_array(jsonb_build_object('provider','supabase','bucket',legacy.bucket_id,'path',legacy.name,'verified',true)));
end;
$$;

create function public.prepare_service_media(p_bucket text,p_path text,p_content_type text,p_byte_size bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare item media_private.objects;
declare rules storage.buckets;
begin
    if auth.role() is distinct from 'service_role' or p_bucket not in ('shop-profile-images','menu-images','event-images') then raise insufficient_privilege; end if;
    select * into rules from storage.buckets where id=p_bucket;
    if rules.id is null or p_byte_size is null or p_byte_size<=0 or (rules.file_size_limit is not null and p_byte_size>rules.file_size_limit)
       or p_content_type not in ('image/jpeg','image/png','image/webp') then raise exception 'Invalid media upload'; end if;
    if not (select write_enabled from media_private.settings) then return jsonb_build_object('provider','supabase'); end if;
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    insert into media_private.objects(bucket,path,content_type,byte_size) values(p_bucket,p_path,p_content_type,p_byte_size) on conflict(bucket,path) do nothing;
    select * into item from media_private.objects where bucket=p_bucket and path=p_path;
    if item.state not in ('pending','ready') or item.content_type is distinct from p_content_type or item.byte_size is distinct from p_byte_size then raise exception 'Media identity conflict'; end if;
    return to_jsonb(item)||jsonb_build_object('provider','gcs','legacy_required',(select legacy_required from media_private.settings));
end;
$$;

create function public.delete_service_media(p_bucket text,p_path text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare media_id uuid;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    select id into media_id from media_private.objects where bucket=p_bucket and path=p_path;
    if media_id is not null then perform media_private.queue_delete(media_id); end if;
    return media_id;
end;
$$;
revoke all on function public.fetch_service_media(uuid,text,text),public.prepare_service_media(text,text,text,bigint),public.delete_service_media(text,text) from public,anon,authenticated;
grant execute on function public.fetch_service_media(uuid,text,text),public.prepare_service_media(text,text,text,bigint),public.delete_service_media(text,text) to service_role;

-- Legacy clients still delete through the Storage API. Preserve that intent in GCS.
create function media_private.on_legacy_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
declare media_id uuid;
begin
    select o.id into media_id from media_private.objects o
    join media_private.locations l on l.media_id=o.id and l.provider='supabase' and not l.deleted
    where o.bucket=old.bucket_id and o.path=old.name and o.state in ('pending','ready');
    if media_id is not null then perform media_private.queue_delete(media_id); end if;
    return old;
end;
$$;
revoke all on function media_private.on_legacy_delete() from public;
create trigger media_legacy_object_deleted after delete on storage.objects
for each row execute function media_private.on_legacy_delete();

create function public.account_has_external_media(p_user_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    return exists(select 1 from media_private.objects o join media_private.locations l on l.media_id=o.id
      where o.owner_id=p_user_id and l.provider='gcs' and not l.deleted);
end;
$$;
revoke all on function public.account_has_external_media(uuid) from public,anon,authenticated;
grant execute on function public.account_has_external_media(uuid) to service_role;

create function public.media_inventory(p_after text default '',p_limit integer default 500) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    return (select coalesce(jsonb_agg(to_jsonb(inventory)),'[]') from (
      select s.bucket_id as bucket,s.name as path,(s.metadata->>'size')::bigint as byte_size,
        s.metadata->>'mimetype' as content_type,s.updated_at,s.bucket_id||'/'||s.name as cursor,
        coalesce(l.verified and not l.deleted and l.source_updated_at=s.updated_at,false) as copied,
        l.bucket as physical_bucket,l.path as object_key,l.generation,o.checksum
      from storage.objects s left join media_private.objects o on o.bucket=s.bucket_id and o.path=s.name
      left join media_private.locations l on l.media_id=o.id and l.provider='gcs'
      where s.bucket_id in ('shop-profile-images','event-images','menu-images','shop-review-images','profile-avatars','news-report-evidence')
        and s.bucket_id||'/'||s.name>p_after and (o.id is null or o.state='ready')
      order by s.bucket_id||'/'||s.name limit least(greatest(p_limit,1),500)
    ) inventory);
end;
$$;
revoke all on function public.media_inventory(text,integer) from public,anon,authenticated;
grant execute on function public.media_inventory(text,integer) to service_role;

commit;
