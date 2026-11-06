-- Keep the HTTP extension outside exposed schemas. Unlike pg_net, pgsql-http
-- does not persist the webhook URL in a client-readable request queue.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated, service_role;
create extension if not exists http with schema private;

do $$
begin
    if not exists (
        select 1
        from pg_catalog.pg_extension extension
        join pg_catalog.pg_namespace namespace
            on namespace.oid = extension.extnamespace
        where extension.extname = 'http' and namespace.nspname = 'private'
    ) then
        raise exception 'http extension must be installed in the private schema';
    end if;
end;
$$;

create table private.community_report_discord_outbox (
    report_id uuid primary key references public.community_reports(id) on delete cascade,
    target_type text not null,
    target_id uuid not null,
    reason text not null,
    reported_at timestamptz not null,
    report_status text not null,
    delivery_state text not null default 'queued'
        check (delivery_state in ('queued', 'sent', 'failed')),
    attempted_at timestamptz,
    http_status integer
);

alter table private.community_report_discord_outbox enable row level security;
revoke all on private.community_report_discord_outbox
    from public, anon, authenticated, service_role;

create index community_report_discord_outbox_queued_idx
    on private.community_report_discord_outbox (reported_at, report_id)
    where delivery_state = 'queued';

create function private.enqueue_community_report_discord()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into private.community_report_discord_outbox (
        report_id,
        target_type,
        target_id,
        reason,
        reported_at,
        report_status
    ) values (
        new.id,
        new.target_type,
        new.target_id,
        new.reason,
        new.created_at,
        new.status
    );
    return new;
exception when others then
    -- A notification failure must not undo a report submission.
    return new;
end;
$$;

revoke all on function private.enqueue_community_report_discord()
    from public, anon, authenticated, service_role;

create trigger enqueue_community_report_discord
after insert on public.community_reports
for each row execute function private.enqueue_community_report_discord();

create function private.dispatch_community_report_discord()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    webhook_url text;
    queued_report record;
    response_status integer;
begin
    select decrypted_secret into webhook_url
    from vault.decrypted_secrets
    where name = 'community_reports_discord_webhook_url';

    if webhook_url is null
        or webhook_url !~ '^https://discord[.]com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$'
    then
        return;
    end if;

    perform private.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '2000');
    perform private.http_set_curlopt('CURLOPT_TIMEOUT_MS', '5000');

    for queued_report in
        select report_id, target_type, target_id, reason, reported_at, report_status
        from private.community_report_discord_outbox
        where delivery_state = 'queued'
        order by reported_at, report_id
        limit 20
        for update skip locked
    loop
        begin
            select response.status into response_status
            from private.http_post(
                webhook_url,
                pg_catalog.jsonb_build_object(
                    'content', pg_catalog.format(
                        E'신고 접수\n신고 ID: %s\n대상: %s / %s\n사유: %s\n접수 시각: %s\n상태: %s',
                        queued_report.report_id,
                        queued_report.target_type,
                        queued_report.target_id,
                        case queued_report.reason
                            when 'spam' then '스팸'
                            when 'harassment' then '괴롭힘'
                            when 'hate' then '혐오 표현'
                            when 'sexual_content' then '성적 콘텐츠'
                            when 'violence' then '폭력'
                            when 'privacy' then '개인정보 침해'
                            when 'other' then '기타'
                            else '기타'
                        end,
                        queued_report.reported_at,
                        queued_report.report_status
                    ),
                    'allowed_mentions', pg_catalog.jsonb_build_object(
                        'parse', pg_catalog.jsonb_build_array()
                    )
                )::text,
                'application/json'
            ) as response;

            update private.community_report_discord_outbox
            set delivery_state = case
                    when response_status between 200 and 299 then 'sent'
                    else 'failed'
                end,
                attempted_at = pg_catalog.clock_timestamp(),
                http_status = response_status
            where report_id = queued_report.report_id;
        exception when others then
            update private.community_report_discord_outbox
            set delivery_state = 'failed',
                attempted_at = pg_catalog.clock_timestamp()
            where report_id = queued_report.report_id;
        end;
    end loop;
end;
$$;

revoke all on function private.dispatch_community_report_discord()
    from public, anon, authenticated, service_role;

select cron.schedule(
    'community-report-discord-dispatch',
    '* * * * *',
    'select private.dispatch_community_report_discord();'
);
