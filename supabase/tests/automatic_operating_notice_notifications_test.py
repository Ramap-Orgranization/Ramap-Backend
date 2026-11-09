#!/usr/bin/env python3
"""공지 등록부터 구독자 발행까지 격리 PostgreSQL에서 검증한다. 외부 발송 없음."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
USER = '00000000-0000-0000-0000-000000000001'
OTHER = '00000000-0000-0000-0000-000000000002'
SHOP = '10000000-0000-4000-8000-000000000001'


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def run(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    return result.stdout.strip()


def main():
    with tempfile.TemporaryDirectory(prefix='ramap-auto-notice-', dir='/tmp') as temporary:
        root = Path(temporary)
        data = root / 'data'
        run('initdb', '-D', str(data), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8')
        run('pg_ctl', '-D', str(data), '-l', str(root/'postgres.log'), '-o', f"-k {root} -c listen_addresses=''", '-w', 'start')
        try:
            psql = ('psql', '-X', '-qAt', '-h', str(root), '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1')

            def sql(query, role='service_role'):
                return run(*psql, '-c', (f'set role {role};' if role else '') + query)

            def value(query):
                output = sql(query)
                return json.loads(output) if output else None

            run(*psql, '-f', str(ROOT/'tests/fixtures/notification_publication.sql'))
            sql("alter table public.ramen_shops add column name text not null default '테스트 매장';", None)
            for name in ['20261108120347_shop_notification_catalog.sql', '20261108145520_notification_selection_preservation.sql', '20261108150336_notification_publication_pipeline.sql', '20261109010000_notification_notice_deep_link_protocol.sql', '20261109020057_automatic_operating_notice_notifications.sql']:
                run(*psql, '-f', str(ROOT/'migrations'/name))
            sql(f"insert into public.ramen_shops(id) values('{SHOP}'); insert into public.shop_operating_notification_subscriptions(user_id,shop_id,type_id) select '{USER}','{SHOP}',unnest(array['temporary_closure','early_closing','shortened_hours']);")
            for identifier, account, protocol in [('supported-device-0001', USER, 1), ('legacy-device-0000001', USER, 0), ('unsubscribed-device-01', OTHER, 1)]:
                sql(f"insert into public.push_registrations(identifier,user_id,platform,target_type,supported_protocol_version) values('{identifier}','{account}','android','token',{protocol})")

            def notice(kind='full_close', date="(now() at time zone 'Asia/Seoul')::date", extra=''):
                notice_id = str(uuid.uuid4())
                end = 'null' if kind == 'full_close' else "'18:00'"
                sql(f"insert into public.admin_shop_operating_notice_records(id,shop_id,raw_post_id,notice_type,description,notice_date,end_date,end_time,source_url{',announcement_id' if extra else ''}) values('{notice_id}','{SHOP}',gen_random_uuid(),'{kind}',E'공식 공지\\n내용',{date},{date},{end},'https://www.instagram.com/p/verified/'{',' + quote(extra) if extra else ''})")
                return notice_id

            def document(notice_id):
                return value(f"select notification_private.operating_notice_document('{notice_id}')")

            def publish(notice_id, document):
                encoded = quote(json.dumps(document, ensure_ascii=False)) if document is not None else 'null'
                return value(f"select public.publish_operating_notice_notification('{notice_id}',{encoded}::jsonb)")

            old = notice()
            assert sql('select count(*) from notification_private.operating_notice_queue') == '0'
            sql('update notification_private.settings set operating_notice_automatic_enabled=true')
            first = notice()
            assert value('select public.fetch_pending_operating_notice_publications(20)') == []
            sql('update notification_private.settings set transport_enabled=true')
            pending = value('select public.fetch_pending_operating_notice_publications(20)')
            assert [x['notice_id'] for x in pending] == [first]
            doc = pending[0]['document']
            assert doc['facts'][0]['message'] == '공식 공지 내용'
            module = (ROOT/'functions/_shared/notification-publication.ts').as_uri()
            run('node', '--input-type=module', '-e', f"import {{previewPublication,validatePublicationDocument}} from '{module}'; let text=''; for await (const chunk of process.stdin) text+=chunk; previewPublication(validatePublicationDocument(JSON.parse(text)));", input=json.dumps(doc))

            # Two dispatchers racing on one notice create one publication/delivery.
            with ThreadPoolExecutor(max_workers=2) as executor:
                outcomes = list(executor.map(lambda _: publish(first, doc), range(2)))
            assert sum(bool(x.get('published')) for x in outcomes) == 1
            aid = next(x['announcement_id'] for x in outcomes if x.get('published'))
            assert sql(f"select count(*) from notification_private.deliveries where announcement_id='{aid}'") == '1'
            assert sql(f"select registration_identifier from notification_private.deliveries where announcement_id='{aid}'") == 'supported-device-0001'
            sql(f"update public.admin_shop_operating_notice_records set description='변경된 공지' where id='{first}'")
            assert sql(f"select status from notification_private.deliveries where announcement_id='{aid}'") == 'cancelled'
            assert sql(f"select status from notification_private.revisions where announcement_id='{aid}'") == 'invalidated'

            for kind, category in [('early_close','early_closing'), ('planned_close','shortened_hours')]:
                nid = notice(kind)
                doc = document(nid)
                assert doc['facts'][0]['type_id'] == category
                assert doc['facts'][0]['ends_at'] == '18:00'
                result = publish(nid, doc)
                sql(f"delete from public.admin_shop_operating_notice_records where id='{nid}'")
                assert sql(f"select status from notification_private.deliveries where announcement_id='{result['announcement_id']}'") == 'cancelled'

            changed = notice()
            stale = document(changed)
            sql(f"update public.admin_shop_operating_notice_records set description='수정 내용' where id='{changed}'")
            try:
                publish(changed, stale)
                raise AssertionError('stale preview accepted')
            except RuntimeError as error:
                assert 'operating_notice_changed' in str(error)
            assert sql(f"select announcement_id is null from operating_notice_private.shop_operating_notices where id='{changed}'") == 't'
            expired = notice(date="(now() at time zone 'Asia/Seoul')::date-1")
            assert document(expired) is None
            assert publish(expired, None)['skipped']
            # Explicit publication reservation avoids automatic ownership.
            explicit = value(f"select public.notification_publication_command('draft',null,0,{quote(json.dumps(document(changed)))}::jsonb,'explicit-draft')")
            reserved = notice(extra=explicit['announcement_id'])
            assert sql(f"select count(*) from notification_private.operating_notice_queue where notice_id='{reserved}'") == '0'
            for _ in range(5):
                sql(f"select public.record_operating_notice_publication_failure('{changed}','invalid_fact_text')")
            assert changed not in [x['notice_id'] for x in value('select public.fetch_pending_operating_notice_publications(20)')]
            assert sql("select has_function_privilege('authenticated','public.publish_operating_notice_notification(uuid,jsonb)','execute')") == 'f'
            assert sql("select has_table_privilege('anon','notification_private.operating_notice_queue','select')") == 'f'
            # Scheduler uses private configuration and makes no request when OFF.
            sql("""create schema vault; create table vault.decrypted_secrets(name text,decrypted_secret text);
                create schema net; create table net.requests(url text,headers jsonb,body jsonb);
                create function net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) returns bigint language plpgsql as $$ begin insert into net.requests values(url,headers,body); return 1; end; $$;
                create schema cron; create table cron.jobs(name text,schedule text,command text);
                create function cron.schedule(name text,schedule text,command text) returns bigint language plpgsql as $$ begin insert into cron.jobs values(name,schedule,command); return 1; end; $$;""", None)
            run(*psql, '-f', str(ROOT/'migrations/20261109020218_schedule_notification_publications.sql'))
            assert sql('select notification_private.request_dispatch()', None) == ''
            sql("insert into vault.decrypted_secrets values('notification_publication_url','https://example.com/dispatch'),('notification_dispatch_secret','test-only-secret');", None)
            sql('update notification_private.settings set transport_enabled=false')
            assert sql('select notification_private.request_dispatch()', None) == ''
            sql('update notification_private.settings set transport_enabled=true')
            assert sql('select notification_private.request_dispatch()', None) == '1'
            assert sql("select body->>'limit' from net.requests", None) == '20'
            assert sql("select has_function_privilege('authenticated','notification_private.request_dispatch()','execute')") == 'f'
            print('PASS: automatic queue, no backfill, transport gate, canonical payload, concurrent deduplication, consent/protocol, edit/delete cancellation, category mapping, stale preview, expiry, explicit linkage, bounded retry, permissions')
        finally:
            run('pg_ctl', '-D', str(data), '-m', 'immediate', '-w', 'stop')


if __name__ == '__main__':
    main()
