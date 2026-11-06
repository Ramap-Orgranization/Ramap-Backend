-- Report photos are private. Existing random root paths remain compatible.
-- Administrator membership is provisioned separately using verified Auth UUIDs.
begin;

create table community_private.news_report_evidence_administrators (
    user_id uuid primary key references auth.users(id) on delete cascade,
    created_at timestamptz not null default now()
);
alter table community_private.news_report_evidence_administrators enable row level security;
revoke all on community_private.news_report_evidence_administrators from public, anon, authenticated;
grant select, insert, delete on community_private.news_report_evidence_administrators to service_role;

create function community_private.can_read_news_report_evidence(p_owner_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
    select exists (
        select 1 from auth.users as live_user
        where live_user.id = auth.uid()
            and not exists (
                select 1 from public.account_deletion_requests as deletion
                where deletion.user_id = live_user.id
            )
    ) and (
        p_owner_id = auth.uid()::text
        or exists (
            select 1 from community_private.news_report_evidence_administrators as administrator
            where administrator.user_id = auth.uid()
        )
    );
$function$;

create function community_private.can_delete_news_report_evidence(p_name text, p_owner_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
    select community_private.can_read_news_report_evidence(p_owner_id)
        and (
            exists (
                select 1 from community_private.news_report_evidence_administrators as administrator
                where administrator.user_id = auth.uid()
            )
            or not exists (
                select 1 from public.feedback_submissions as report
                where report.attachment_path = p_name
            )
        );
$function$;

revoke all on function community_private.can_read_news_report_evidence(text) from public;
revoke all on function community_private.can_delete_news_report_evidence(text, text) from public;
grant execute on function community_private.can_read_news_report_evidence(text) to anon, authenticated, service_role;
grant execute on function community_private.can_delete_news_report_evidence(text, text) to anon, authenticated, service_role;

update storage.buckets
set public = false
where id = 'news-report-evidence';

drop policy "Anyone can upload news report evidence" on storage.objects;
drop policy "Anyone can remove failed news report evidence" on storage.objects;

create policy "Reporters can upload their own news report evidence"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'news-report-evidence'
    and owner_id = (select auth.uid())::text
);

create policy "Reporters and administrators can read news report evidence"
on storage.objects for select to authenticated
using (
    bucket_id = 'news-report-evidence'
    and community_private.can_read_news_report_evidence(owner_id)
);

create policy "Reporters can clean unused evidence and administrators can remove evidence"
on storage.objects for delete to authenticated
using (
    bucket_id = 'news-report-evidence'
    and community_private.can_delete_news_report_evidence(name, owner_id)
);

-- Restrictive guards prevent broader policies on other buckets from bypassing
-- this bucket's ownership boundary. Service-role processing remains unchanged.
create policy "News report evidence read boundary"
on storage.objects as restrictive for select to public
using (
    bucket_id <> 'news-report-evidence'
    or community_private.can_read_news_report_evidence(owner_id)
);

create policy "News report evidence upload boundary"
on storage.objects as restrictive for insert to public
with check (
    bucket_id <> 'news-report-evidence'
    or (
        owner_id = (select auth.uid())::text
        and community_private.can_read_news_report_evidence(owner_id)
    )
);

create policy "News report evidence cleanup boundary"
on storage.objects as restrictive for delete to public
using (
    bucket_id <> 'news-report-evidence'
    or community_private.can_delete_news_report_evidence(name, owner_id)
);

create policy "News report evidence is immutable after upload"
on storage.objects as restrictive for update to public
using (bucket_id <> 'news-report-evidence')
with check (bucket_id <> 'news-report-evidence');

CREATE OR REPLACE FUNCTION public.submit_news_report(p_source_url text DEFAULT NULL::text, p_attachment_path text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'storage'
AS $function$
begin
    if nullif(btrim(p_source_url), '') is null and p_attachment_path is null then
        raise exception 'news report requires source URL or evidence';
    end if;

    if p_attachment_path is not null then
        perform community_private.require_live_user();

        if not exists (
            select 1
            from storage.objects
            where bucket_id = 'news-report-evidence'
                and name = p_attachment_path
                and owner_id = auth.uid()::text
        ) then
            raise exception 'news report evidence is not owned by the reporter'
                using errcode = '42501';
        end if;
    end if;

    if p_attachment_path is not null and not exists (
        select 1
        from storage.objects
        where bucket_id = 'news-report-evidence'
            and name = p_attachment_path
    ) then
        raise exception 'news report evidence does not exist';
    end if;

    if nullif(btrim(p_source_url), '') is not null then
        insert into public.feedback_submissions (feedback_type, message, attachment_path)
        values ('news_report', btrim(p_source_url), p_attachment_path)
        on conflict (message)
            where feedback_type = 'news_report' and nullif(btrim(message), '') is not null
            do nothing;

        if not found then
            return 'duplicate';
        end if;
    else
        insert into public.feedback_submissions (feedback_type, message, attachment_path)
        values ('news_report', '', p_attachment_path);
    end if;

    return 'submitted';
end;
$function$;

CREATE OR REPLACE FUNCTION public.notify_discord_feedback_submission()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'vault', 'net'
AS $function$
declare
    webhook_url text;
    content text;
    evidence_url text;
begin
    select decrypted_secret
    into webhook_url
    from vault.decrypted_secrets
    where name = 'discord_feedback_webhook_url'
    limit 1;

    if nullif(btrim(webhook_url), '') is null then
        return new;
    end if;

    content := format(E'새 피드백 제보\n유형: %s', new.feedback_type);

    if nullif(btrim(new.message), '') is not null then
        content := content || format(E'\n내용: %s', btrim(new.message));
    end if;

    if new.attachment_path is not null then
        evidence_url := 'https://supabase.com/dashboard/project/clbhayqiwjawaawvrhcq/storage/buckets/news-report-evidence';
        content := content || format(E'\n사진: %s (%s)', evidence_url, new.attachment_path);
    end if;

    perform net.http_post(
        url := webhook_url,
        body := jsonb_build_object(
            'content', left(content, 2000),
            'allowed_mentions', jsonb_build_object('parse', jsonb_build_array())
        ),
        headers := jsonb_build_object('Content-Type', 'application/json'),
        timeout_milliseconds := 5000
    );

    return new;
exception
    when others then
        raise warning 'Discord feedback notification could not be queued';
        return new;
end;
$function$;

commit;
