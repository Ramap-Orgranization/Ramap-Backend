begin;

set local lock_timeout = '5s';
lock table media_private.objects in share row exclusive mode;

do $$
begin
    if not exists (select 1 from media_private.settings where r2_read_enabled and r2_write_enabled) then
        raise exception 'Enable R2 reads and writes before retiring Supabase photo serving';
    end if;

    if exists (
        select 1 from media_private.objects
        where state = 'pending' and upload_expires_at > now() and 'supabase' = any(required_providers)
    ) then
        raise exception 'Finish existing Supabase mirror uploads before retiring photo serving';
    end if;

    if exists (
        select 1 from media_private.copy_references() ref
        where ref.reason in ('current_event', 'current_reference', 'retained_evidence')
          and nullif(ref.path, '') is not null
          -- Public references that were already missing have no Supabase bytes to retire.
          and (ref.bucket in ('shop-review-images', 'profile-avatars', 'news-report-evidence')
               or exists (select 1 from storage.objects st where st.bucket_id = ref.bucket and st.name = ref.path))
          and not exists (
              select 1 from media_private.objects o
              join media_private.locations l on l.media_id = o.id
              where o.bucket = ref.bucket and o.path = ref.path and o.state = 'ready'
                and l.provider = 'r2' and l.verified and not l.deleted
          )
    ) then
        raise exception 'Copy all referenced photos to R2 before retiring Supabase photo serving';
    end if;
end;
$$;

update media_private.settings set legacy_required = false where singleton;

-- Expired legacy attempts may still be cleaned up. New pending rows must be R2-only,
-- including requests that read the old setting before this migration obtained the lock.
alter table media_private.objects add constraint pending_photo_does_not_require_supabase
    check (state <> 'pending' or not ('supabase' = any(required_providers))) not valid;

create or replace function public.list_account_review_photo_copies(p_user_id uuid)
returns table(source_path text, destination_path text)
language plpgsql stable security definer
set search_path = ''
as $$
begin
    if auth.role() is distinct from 'service_role'
       or not exists (select 1 from public.account_deletion_requests where user_id = p_user_id)
    then raise insufficient_privilege; end if;

    return query
    select photo.source_path, photo.destination_path
    from media_private.account_review_photos_to_preserve(p_user_id) photo
    where not exists (
        select 1 from media_private.objects o
        join media_private.locations l on l.media_id = o.id
        where o.bucket = 'shop-review-images' and o.path = photo.destination_path
          and o.owner_id is null and o.state = 'ready' and l.provider = 'r2' and l.verified and not l.deleted
    )
    order by photo.review_id, photo.photo_order
    limit 24;
end;
$$;

create function public.reserve_withdrawn_review_photo(
    p_user_id uuid, p_source_path text, p_destination_path text, p_bucket text
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare source media_private.objects;
declare destination media_private.objects;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    perform 1 from auth.users where id = p_user_id for key share;
    if not found
       or not exists (select 1 from public.account_deletion_requests where user_id = p_user_id)
       or not exists (
           select 1 from media_private.account_review_photos_to_preserve(p_user_id) photo
           where photo.source_path = p_source_path and photo.destination_path = p_destination_path
       )
    then raise insufficient_privilege; end if;
    if nullif(p_bucket, '') is null then raise exception 'Invalid R2 bucket'; end if;

    select o.* into source
    from media_private.objects o
    join media_private.locations l on l.media_id = o.id
    where o.bucket = 'shop-review-images' and o.path = p_source_path and o.state = 'ready'
      and l.provider = 'r2' and l.verified and not l.deleted;
    if not found or source.checksum is null then raise exception 'Verified R2 review source unavailable'; end if;

    perform pg_advisory_xact_lock(hashtextextended(p_destination_path, 0));
    select * into destination from media_private.objects
    where bucket = 'shop-review-images' and path = p_destination_path for update;

    if not found then
        insert into media_private.objects(bucket, path, byte_size, content_type, checksum, required_providers)
        values ('shop-review-images', p_destination_path, source.byte_size, source.content_type, source.checksum, '{}')
        returning * into destination;
    elsif destination.owner_id is not null or destination.byte_size is distinct from source.byte_size
       or destination.content_type is distinct from source.content_type or destination.checksum is distinct from source.checksum then
        raise exception 'Withdrawn review copy identity changed';
    end if;

    if destination.state = 'ready' and exists (
        select 1 from media_private.locations where media_id = destination.id
          and provider = 'r2' and verified and not deleted
    ) then return to_jsonb(destination); end if;
    if destination.state = 'deleted'
       and not exists (select 1 from media_private.cleanup where media_id = destination.id)
       and not exists (select 1 from media_private.locations where media_id = destination.id and not deleted) then
        update media_private.objects set state = 'pending', upload_expires_at = now() + interval '10 minutes'
        where id = destination.id returning * into destination;
    end if;
    if destination.state <> 'pending' or destination.upload_expires_at < now() + interval '1 minute' then
        raise exception 'Withdrawn review copy is awaiting cleanup';
    end if;

    insert into media_private.locations(media_id, provider, bucket, path)
    values (destination.id, 'r2', p_bucket, destination.bucket || '/' || destination.path)
    on conflict (media_id, provider) do update set deleted = false, verified = false, etag = null
    where media_private.locations.deleted and media_private.locations.bucket = excluded.bucket
      and media_private.locations.path = excluded.path;
    if not exists (
        select 1 from media_private.locations l where l.media_id = destination.id
        and l.provider = 'r2' and l.bucket = p_bucket and l.path = destination.bucket || '/' || destination.path and not l.deleted
    ) then raise exception 'Withdrawn review copy target changed'; end if;

    return to_jsonb(destination);
end;
$$;

create function public.finish_withdrawn_review_photo(
    p_user_id uuid, p_id uuid, p_expires_at timestamptz, p_etag text, p_checksum text
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare destination media_private.objects;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    select * into destination from media_private.objects where id = p_id;
    if not found or destination.owner_id is not null or destination.bucket <> 'shop-review-images' then
        raise exception 'Invalid withdrawn review copy';
    end if;
    perform 1 from auth.users where id = p_user_id for key share;
    perform pg_advisory_xact_lock(hashtextextended(destination.path, 0));
    select * into destination from media_private.objects where id = p_id for update;

    if destination.upload_expires_at is distinct from p_expires_at then
        raise exception 'Withdrawn review copy reservation expired';
    end if;
    if p_checksum is null or destination.checksum is distinct from p_checksum or nullif(p_etag, '') is null then
        raise exception 'Withdrawn review copy verification failed';
    end if;
    if destination.state = 'ready' and exists (
        select 1 from media_private.locations where media_id = p_id and provider = 'r2'
          and verified and not deleted and etag = p_etag
    ) then return; end if;

    if destination.state <> 'pending' or destination.upload_expires_at <= now()
       or not exists (select 1 from public.account_deletion_requests where user_id = p_user_id)
       or not exists (
           select 1 from media_private.account_review_photos_to_preserve(p_user_id) photo
           where photo.destination_path = destination.path
       )
    then raise exception 'Withdrawn review copy changed before verification'; end if;

    update media_private.locations set verified = true, etag = p_etag
    where media_id = p_id and provider = 'r2' and not deleted;
    if not found then raise exception 'Withdrawn review copy target unavailable'; end if;
    update media_private.objects set state = 'ready' where id = p_id;
end;
$$;

create or replace function media_private.claim_cleanup(p_id uuid,p_limit integer,p_user_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare item media_private.objects;
declare result jsonb;
begin
    if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
    for item in
        select * from media_private.objects
        where state='pending' and upload_expires_at<now()
          and (p_id is null or id=p_id) and (p_user_id is null or owner_id=p_user_id)
        order by path limit 100
    loop
        -- A withdrawn-photo reservation may have been reopened after this scan.
        perform pg_advisory_xact_lock(hashtextextended(item.path, 0));
        if exists (
            select 1 from media_private.objects
            where id = item.id and state = 'pending' and upload_expires_at < now()
        ) then
            perform media_private.queue_delete(item.id);
        end if;
    end loop;
    with selected as (
        select q.id from media_private.cleanup q
        where q.not_before<=now() and (q.lease_until is null or q.lease_until<now())
          and (p_id is null or q.media_id=p_id)
          and (p_user_id is null or exists(select 1 from media_private.objects o where o.id=q.media_id and o.owner_id=p_user_id))
        order by q.id for update of q skip locked limit least(greatest(p_limit,1),100)
    ), leased as (
        update media_private.cleanup q set lease_until=now()+interval '5 minutes',attempts=attempts+1
        from selected where q.id=selected.id returning q.*
    ) select coalesce(jsonb_agg(to_jsonb(leased)),'[]') into result from leased;
    return result;
end;
$$;

revoke all on function public.list_account_review_photo_copies(uuid),
    public.reserve_withdrawn_review_photo(uuid, text, text, text),
    public.finish_withdrawn_review_photo(uuid, uuid, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.list_account_review_photo_copies(uuid),
    public.reserve_withdrawn_review_photo(uuid, text, text, text),
    public.finish_withdrawn_review_photo(uuid, uuid, timestamptz, text, text) to service_role;

commit;
