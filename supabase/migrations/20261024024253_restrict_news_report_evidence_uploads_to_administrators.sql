begin;

-- User photo reports are removed; administrators still upload registration evidence.
create function community_private.can_upload_news_report_evidence(p_owner_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
    select p_owner_id = auth.uid()::text
        and community_private.can_read_news_report_evidence(p_owner_id)
        and exists (
            select 1
            from community_private.news_report_evidence_administrators as administrator
            where administrator.user_id = auth.uid()
        );
$function$;

revoke all on function community_private.can_upload_news_report_evidence(text) from public;
grant execute on function community_private.can_upload_news_report_evidence(text)
    to anon, authenticated, service_role;

drop policy "Reporters can upload their own news report evidence" on storage.objects;

create policy "Administrators can upload their own news report evidence"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'news-report-evidence'
    and community_private.can_upload_news_report_evidence(owner_id)
);

-- Keep this restrictive so broader policies cannot reopen user uploads.
alter policy "News report evidence upload boundary" on storage.objects
with check (
    bucket_id <> 'news-report-evidence'
    or community_private.can_upload_news_report_evidence(owner_id)
);

commit;
