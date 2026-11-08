begin;

set local lock_timeout = '5s';
lock table media_private.settings, media_private.objects in share row exclusive mode;

do $$
begin
    if not exists (
        select 1 from media_private.settings
        where r2_read_enabled and r2_write_enabled and not legacy_required
    ) then raise exception 'Retire Supabase photo serving before removing its buckets'; end if;
    if exists (
        select 1 from media_private.objects
        where state = 'pending' and 'supabase' = any(required_providers)
          and (upload_expires_at > now() or finalizing_until > now())
    ) then raise exception 'Finish Supabase mirror uploads before removing its buckets'; end if;
    if exists (
        select 1 from media_private.copy_references() ref
        where ref.reason in ('current_event', 'current_reference', 'retained_evidence')
          and nullif(ref.path, '') is not null
          and (ref.bucket in ('shop-review-images', 'profile-avatars', 'news-report-evidence')
               or exists (select 1 from storage.objects s where s.bucket_id = ref.bucket and s.name = ref.path))
          and not exists (
              select 1 from media_private.objects o
              join media_private.locations l on l.media_id = o.id
              where o.bucket = ref.bucket and o.path = ref.path and o.state = 'ready'
                and l.provider = 'r2' and l.verified and not l.deleted
          )
    ) then raise exception 'Copy referenced photos to R2 before removing Supabase buckets'; end if;
end;
$$;

create table media_private.buckets (
    id text primary key check (id in (
        'shop-review-images', 'profile-avatars', 'news-report-evidence',
        'shop-profile-images', 'menu-images', 'event-images'
    )),
    public boolean not null,
    file_size_limit bigint,
    allowed_mime_types text[]
);
alter table media_private.buckets enable row level security;
revoke all on media_private.buckets from public, anon, authenticated;
insert into media_private.buckets (id, public, file_size_limit, allowed_mime_types)
select id, public, file_size_limit, allowed_mime_types from storage.buckets
where id in ('shop-review-images', 'profile-avatars', 'news-report-evidence',
             'shop-profile-images', 'menu-images', 'event-images');
do $$ begin
    if (select count(*) from media_private.buckets) <> 6 then
        raise exception 'Preserve all six photo bucket rules before removing storage buckets';
    end if;
end; $$;

alter table media_private.objects drop constraint objects_bucket_fkey;
alter table media_private.objects add constraint objects_bucket_fkey
    foreign key (bucket) references media_private.buckets(id);

create or replace function media_private.prepare_upload(p_bucket text,p_path text,p_content_type text,p_byte_size bigint,p_r2 boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare user_id uuid := community_private.require_live_user();
declare item media_private.objects;
declare rules media_private.buckets;
declare policy jsonb := media_private.upload_policy(p_r2,p_bucket);
begin
    select * into rules from media_private.buckets where id=p_bucket;
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
    if not p_r2 or not (select r2_write_enabled from media_private.settings) then raise exception 'R2 media uploads unavailable'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    select * into item from media_private.objects where bucket=p_bucket and path=p_path for update;
    if found then
        if item.owner_id is distinct from user_id or item.content_type is distinct from p_content_type or item.byte_size is distinct from p_byte_size
          or item.state not in ('pending','ready') then raise exception 'Media identity conflict'; end if;
        if item.state='pending' and item.upload_expires_at<=now() then raise exception 'Upload expired'; end if;
    else
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
declare rules media_private.buckets;
declare policy jsonb := media_private.upload_policy(p_r2,p_bucket);
begin
    if auth.role() is distinct from 'service_role' or p_bucket not in ('shop-profile-images','menu-images','event-images') then raise insufficient_privilege; end if;
    select * into rules from media_private.buckets where id=p_bucket;
    if rules.id is null or p_byte_size is null or p_byte_size<=0 or (rules.file_size_limit is not null and p_byte_size>rules.file_size_limit)
       or p_content_type not in ('image/jpeg','image/png','image/webp') then raise exception 'Invalid media upload'; end if;
    if not p_r2 or not (select r2_write_enabled from media_private.settings) then raise exception 'R2 media uploads unavailable'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_path,0));
    insert into media_private.objects(bucket,path,content_type,byte_size,upload_provider,required_providers) values(p_bucket,p_path,p_content_type,p_byte_size,policy->>'provider',array(select jsonb_array_elements_text(policy->'required_providers'))) on conflict(bucket,path) do nothing;
    select * into item from media_private.objects where bucket=p_bucket and path=p_path;
    if item.state not in ('pending','ready') or item.content_type is distinct from p_content_type or item.byte_size is distinct from p_byte_size then raise exception 'Media identity conflict'; end if;
    return to_jsonb(item)||jsonb_build_object('provider',item.upload_provider,'legacy_required','supabase'=any(item.required_providers));
end;
$$;

-- R2 owns photo deletion. Removing a retired Supabase copy must not enqueue R2.
drop trigger media_legacy_object_deleted on storage.objects;
drop function media_private.on_legacy_delete();

update media_private.locations set retired_at = coalesce(retired_at, now())
where provider = 'supabase' and bucket in (select id from media_private.buckets);

commit;
