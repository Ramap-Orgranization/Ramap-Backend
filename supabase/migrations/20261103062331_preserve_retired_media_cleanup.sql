begin;

alter table media_private.locations add column retired_at timestamptz;

-- The retirement migration did not delete cloud objects. Its deleted flag cannot
-- prove absence, even for older tombstones; recheck those locations conservatively.
update media_private.locations set retired_at=now(),deleted=false where provider='gcs';

-- Never resurrect readable media. Previously deleted/fenced accounts retain only
-- cleanup work until the retired object's absence has actually been confirmed.
do $$
declare item media_private.objects;
begin
    for item in
        select o.* from media_private.objects o
        where exists(select 1 from media_private.locations l where l.media_id=o.id and l.retired_at is not null and not l.deleted)
          and (o.state in ('deleting','deleted')
            or exists(select 1 from public.account_deletion_requests r where r.user_id=o.owner_id)
            or (o.owner_id is not null and not exists(select 1 from auth.users u where u.id=o.owner_id)))
        order by o.path
    loop
        update media_private.objects set state='deleting' where id=item.id and state='deleted';
        perform media_private.queue_delete(item.id);
    end loop;
end;
$$;

create function media_private.claim_cleanup(p_id uuid,p_limit integer,p_user_id uuid) returns jsonb
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
        perform media_private.queue_delete(item.id);
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

create or replace function public.claim_media_cleanup(p_id uuid default null,p_limit integer default 50) returns jsonb
language sql security definer set search_path='' as $$
    select media_private.claim_cleanup(p_id,p_limit,null);
$$;

create function public.claim_account_media_cleanup(p_user_id uuid,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
    if auth.role() is distinct from 'service_role'
      or p_user_id is null
      or not exists(select 1 from public.account_deletion_requests where user_id=p_user_id)
    then raise insufficient_privilege; end if;
    return media_private.claim_cleanup(null,p_limit,p_user_id);
end;
$$;

revoke all on function media_private.claim_cleanup(uuid,integer,uuid) from public,anon,authenticated;
revoke all on function public.claim_account_media_cleanup(uuid,integer) from public,anon,authenticated;
grant execute on function public.claim_account_media_cleanup(uuid,integer) to service_role;

commit;
