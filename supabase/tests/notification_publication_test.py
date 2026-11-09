#!/usr/bin/env python3
"""격리 DB에서 선택 보존·발행·전달 상태 계약을 검사한다. 실제 provider는 호출하지 않는다."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

A = '00000000-0000-0000-0000-000000000001'
B = '00000000-0000-0000-0000-000000000002'
SHOP = '10000000-0000-0000-0000-000000000001'
EVENT = '30000000-0000-0000-0000-000000000001'
PARTICIPANT_SHOP = '10000000-0000-0000-0000-000000000003'
NEW = 'test-device-new-0000000001'
OLD = 'test-device-old-0000000001'
OTHER = 'test-device-new-0000000002'


def quoted(value):
    if value is None:
        return 'null'
    return "'" + str(value).replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-migration', type=Path, required=True)
    parser.add_argument('--migration', type=Path, action='append', required=True)
    args = parser.parse_args()
    for executable in ('initdb', 'pg_ctl', 'psql'):
        if not shutil.which(executable):
            raise SystemExit(f'필요한 로컬 PostgreSQL 명령: {executable}')

    def run(*command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout.strip()

    with tempfile.TemporaryDirectory(prefix='ramap-publication-', dir='/tmp') as temporary:
        root = Path(temporary)
        data = root / 'data'
        started = False
        try:
            run('initdb', '-D', str(data), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8')
            run('pg_ctl', '-D', str(data), '-l', str(root/'postgres.log'), '-o', f"-k {root} -c listen_addresses=''", '-w', 'start')
            started = True
            psql = ('psql', '-X', '-qAt', '-h', str(root), '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1')
            fixture = Path(__file__).resolve().parent/'fixtures/notification_publication.sql'
            for source in (fixture, args.base_migration, *args.migration):
                run(*psql, '-f', str(source.resolve()))

            def sql(query, role='service_role', account=None):
                prefix = '' if role is None else f"set role {role}; set request.jwt.claim.sub={quoted(account or '')};"
                return run(*psql, '-c', prefix + query)

            def json_sql(query, role='service_role', account=None):
                value = sql(query, role, account)
                return json.loads(value) if value else None

            def reject(query, marker, role='service_role', account=None):
                try:
                    sql(query, role, account)
                except RuntimeError as failure:
                    assert marker in str(failure), str(failure)
                    return
                raise AssertionError('거절되지 않음: ' + query)

            def snapshot():
                return json_sql(f"select public.fetch_shop_notification_settings('{SHOP}','{A}')", 'authenticated', A)

            def save(ids, clear=False):
                values = 'array[' + ','.join(quoted(x) for x in ids) + ']::text[]'
                return json_sql(f"select public.save_shop_notification_settings('{SHOP}','{A}',{snapshot()['catalog_revision']},{values},{str(clear).lower()})", 'authenticated', A)

            def document(facts):
                return {'source': {'url': 'https://www.instagram.com/p/official-source/', 'raw_text': '원문 보존: 점심 LO 14시 / 저녁 휴무. 다음 날 콜라보.', 'official_verified': True}, 'facts': facts}

            def fact(type_id='temporary_closure', **overrides):
                value = {'id': str(uuid.uuid4()), 'shop_id': SHOP, 'shop_name': '테스트 본점', 'type_id': type_id,
                         'certainty': 'confirmed', 'verified': True, 'starts_on': '2026-11-12', 'ends_on': '2026-11-12',
                         'starts_at': None, 'ends_at': None, 'time_meaning': 'full_day', 'exception_dates': [],
                         'message': '11월 12일 임시휴무', 'context_key': '2026-11-12-main',
                         'destination': {'version': 1, 'action': 'none'}, 'registration_type': 'none', 'registration_id': None}
                value.update(overrides)
                return value

            def command(action, announcement=None, revision=0, doc=None, key=None):
                key = key or str(uuid.uuid4())
                return json_sql(f"select public.notification_publication_command({quoted(action)},{quoted(announcement)},{revision},{quoted(json.dumps(doc, ensure_ascii=False)) if doc is not None else 'null'}::jsonb,{quoted(key)})")

            def publish(doc, event_id=None):
                draft = command('draft', doc=doc)
                aid, rev = draft['announcement_id'], draft['revision']
                if event_id:
                    sql(f"select public.link_notification_registration('{aid}',{rev},'event','{event_id}',true)")
                command('preview', aid, rev)
                command('publish', aid, rev)
                return draft

            def claim(limit=100):
                return json_sql(f'select public.claim_notification_deliveries({limit},30)')

            def prepare(delivery):
                return json_sql(f"select public.prepare_notification_delivery('{delivery['delivery_id']}','{delivery['claim_token']}')")

            def complete(delivery, state='sent'):
                return sql(f"select public.complete_notification_delivery('{delivery['delivery_id']}','{delivery['claim_token']}','{state}','fake-provider-id',null)")

            # Preference preservation: hidden and inactive choices survive ordinary saves.
            save(['event', 'temporary_closure'])
            sql("update public.shop_notification_catalog set is_visible=false where id='temporary_closure'")
            assert save([])['has_hidden_effective_subscription'] is True
            assert sql(f"select count(*) from public.shop_operating_notification_subscriptions where user_id='{A}'") == '1'
            sql("update public.shop_notification_catalog set is_active=false where id='temporary_closure'")
            assert snapshot()['has_effective_subscription'] is False
            save([])
            sql("update public.shop_notification_catalog set is_active=true,is_visible=true,title='휴무 안내',display_order=2 where id='temporary_closure'")
            assert snapshot()['selected_type_ids'] == ['temporary_closure']
            sql("update public.shop_notification_catalog set is_visible=false where id='temporary_closure'")
            save(['event'], clear=True)
            assert sql(f"select count(*) from public.shop_operating_notification_subscriptions where user_id='{A}'") == '0'
            sql("update public.shop_notification_catalog set is_visible=true where id='temporary_closure'")
            save(['event', 'temporary_closure', 'early_closing', 'shortened_hours'])

            # Device ownership/version changes use existing protected registration path.
            sql(f"select public.register_push_registration_protocol('{NEW}','android','token','{A}',1)", 'authenticated', A)
            sql(f"select public.register_push_registration('{OLD}','ios','token')", 'authenticated', A)
            sql(f"select public.register_push_registration_protocol('{NEW}','android','token','{A}',1)", 'authenticated', A)
            assert sql(f"select supported_protocol_version from public.push_registrations where identifier='{NEW}'") == '1'
            reject(f"select public.register_push_registration_protocol('{NEW}','android','token','{A}',3)", 'unsupported_notification_protocol', 'authenticated', A)
            sql(f"select public.register_push_registration_protocol('{NEW}','android','token','{A}',1)", 'authenticated', A)
            sql(f"select public.register_push_registration_protocol('{OTHER}','android','token','{B}',1)", 'authenticated', B)
            reject(f"select public.register_push_registration_protocol('{NEW}','android','token','{B}',1)", 'notification_account_mismatch', 'authenticated', A)
            reject("select public.claim_notification_deliveries(10,30)", 'permission denied', 'authenticated', A)
            reject("select * from notification_private.sources", 'permission denied', 'anon')
            sql(f"insert into public.ramen_shops(id,is_visible) values('{PARTICIPANT_SHOP}',true)")
            sql(f"select public.set_shop_event_notification('{PARTICIPANT_SHOP}',true)", 'authenticated', B)
            sql(f"insert into public.shop_events(id,shop_id,title,start_date) values('{EVENT}','{SHOP}','테스트 이벤트','2026-11-12')")
            sql(f"insert into public.shop_event_participants(event_id,shop_id) values('{EVENT}','{PARTICIPANT_SHOP}')")
            event = fact('event', message='11월 12일 콜라보', registration_type='event', registration_id=EVENT, destination={'version':1,'action':'event_detail','event_id':EVENT})
            operating = fact()
            doc = document([event, operating])
            draft = command('draft', doc=doc, key='draft-once')
            assert command('draft', doc=doc, key='draft-once') == draft
            aid, rev = draft['announcement_id'], draft['revision']
            assert claim() == []
            reject(f"select public.notification_publication_command('publish','{aid}',{rev},null,'before-preview')", 'matching_preview_required')
            reject(f"select public.notification_publication_command('preview','{aid}',{rev},null,'not-ready')", 'notification_registration_not_ready')
            sql(f"select public.link_notification_registration('{aid}',{rev},'event','{EVENT}',true)")
            assert sql(f"select public.claim_event_notification_delivery('{EVENT}','{A}','{NEW}','new_event')") == 'f', '연결 후 standalone 최초 알림 차단'
            assert sql(f"select public.claim_event_notification_delivery('{EVENT}','{A}','{NEW}','day_before')") == 't', '연결 뒤에도 기존 이벤트 전날 리마인더 유지'
            command('preview', aid, rev)
            command('publish', aid, rev, key='publish-once')
            assert command('publish', aid, rev, key='publish-once')['status'] == 'published'
            assert sql('select count(*) from notification_private.deliveries') == '3'
            assert claim() == [], '전송 기본 OFF는 claim을 생성하지 않음'
            sql('update notification_private.settings set transport_enabled=true')
            # Keep first claim's row locks open; SKIP LOCKED must let a second
            # worker finish before commit and claim only the remaining device.
            holder = subprocess.Popen(psql, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
            try:
                holder.stdin.write("begin; set role service_role; select public.claim_notification_deliveries(2,30);\n")
                holder.stdin.flush()
                first_batch = json.loads(holder.stdout.readline())
                with ThreadPoolExecutor(max_workers=1) as executor:
                    second_batch = executor.submit(claim, 2).result(timeout=5)
                assert len(first_batch) == 2 and len(second_batch) == 1
                holder.stdin.write("commit;\n\q\n")
                holder.stdin.flush()
                holder.wait(timeout=5)
                deliveries = first_batch + second_batch
            finally:
                if holder.poll() is None:
                    holder.kill()
                    holder.wait(timeout=5)
            assert len(deliveries) == 3 and len({x['delivery_id'] for x in deliveries}) == 3
            by_device = {x['registration_identifier']: x for x in deliveries}
            assert {f['type_id'] for f in by_device[NEW]['facts']} == {'event','temporary_closure'}
            assert [f['type_id'] for f in by_device[OLD]['facts']] == ['event']
            assert [f['type_id'] for f in by_device[OTHER]['facts']] == ['event'], '참가 매장 이벤트 구독자는 이벤트만 받고 미선택 운영 사실은 제외'
            assert sql(f"select count(*) from public.shop_event_notification_subscriptions where user_id='{B}' and shop_id='{SHOP}'") == '0'
            assert 'raw_text' not in json.dumps(deliveries)
            # Global event OFF does not suppress operating facts; re-read just before send.
            sql(f"insert into public.user_event_notification_preferences values('{A}',false)")
            ready = prepare(by_device[NEW])
            assert [f['type_id'] for f in ready['facts']] == ['temporary_closure']
            assert prepare(by_device[OLD]) is None
            assert complete(by_device[NEW]) == 't'
            sql(f"update public.push_registrations set user_id='{A}' where identifier='{OTHER}'")
            assert prepare(by_device[OTHER]) is None, '기기 소유자 변경은 이전 계정 전달 취소'
            assert claim() == []

            # Link canonical notice even when the public view filters it out.
            notice_id = '40000000-0000-0000-0000-000000000001'
            sql(f"insert into public.admin_shop_operating_notice_records(id,shop_id,raw_post_id,notice_type,notice_date,source_url) values('{notice_id}','{SHOP}','{uuid.uuid4()}','planned_close','2026-11-12','https://www.instagram.com/p/notice/')")
            assert sql(f"select count(*) from public.shop_operating_notices where id='{notice_id}'") == '0'
            notice_document = document([fact(registration_type='operating_notice',registration_id=notice_id)])
            notice_draft = command('draft', doc=notice_document)
            sql(f"select public.link_notification_registration('{notice_draft['announcement_id']}',1,'operating_notice','{notice_id}',true)")
            command('preview', notice_draft['announcement_id'], 1)
            assert sql(f"select announcement_id from operating_notice_private.shop_operating_notices where id='{notice_id}'") == notice_draft['announcement_id']
            assert sql("select count(*) from information_schema.columns where table_schema='public' and table_name in ('shop_operating_notices','admin_shop_operating_notice_records') and column_name='announcement_id'") == '0'
            sql(f"update public.admin_shop_operating_notice_records set end_time='14:00' where id='{notice_id}'")
            assert sql(f"select notice_type||':'||notice_category from public.shop_operating_notices where id='{notice_id}'") == 'early_close:planned_close'
            assert sql(f"select id from public.shop_operating_notices where id='{notice_id}'") == notice_id

            # Correction replaces ranges and only reaches previously delivered facts/devices.
            corrected = dict(operating, starts_on='2026-11-14', ends_on='2026-11-15', message='정정: 11월 14~15일 휴무')
            correction = command('correct', aid, rev, document([corrected]))
            duplicate = command('draft', doc=document([operating]))
            command('preview', duplicate['announcement_id'], duplicate['revision'])
            reject(f"select public.notification_publication_command('publish','{duplicate['announcement_id']}',1,null,'duplicate-during-correction')", 'fact_already_published')
            command('preview', aid, correction['revision'])
            command('publish', aid, correction['revision'])
            correction_rows = claim()
            assert len(correction_rows) == 1 and correction_rows[0]['registration_identifier'] == NEW
            assert correction_rows[0]['facts'][0]['starts_on'] == '2026-11-14'
            assert prepare(correction_rows[0]) is not None
            # A provider timeout/complete failure remains sending; expired sending -> unknown, never resend.
            sql("update notification_private.deliveries set lease_until=now()-interval '1 second' where status='sending'")
            assert claim() == []
            assert sql("select count(*) from notification_private.deliveries where status='unknown'") == '1'

            # Delivered facts cannot disappear or silently switch category in a correction.
            removed = command('correct', aid, correction['revision'], document([fact()]))
            reject(f"select public.notification_publication_command('preview','{aid}',{removed['revision']},null,'removed-delivered')", 'explicit_correction_required')
            retyped = command('correct', aid, removed['revision'], document([dict(corrected, type_id='shortened_hours')]))
            reject(f"select public.notification_publication_command('preview','{aid}',{retyped['revision']},null,'retyped-delivered')", 'explicit_correction_required')
            unchanged_cancel = command('cancel', aid, retyped['revision'], document([corrected]))
            reject(f"select public.notification_publication_command('preview','{aid}',{unchanged_cancel['revision']},null,'unchanged-cancel')", 'explicit_cancellation_message_required')
            cancelled = command('cancel', aid, unchanged_cancel['revision'], document([dict(corrected, message='취소: 앞서 안내한 임시휴무는 취소되었습니다')]))
            command('preview', aid, cancelled['revision'])
            command('publish', aid, cancelled['revision'])
            cancellation_rows = claim()
            assert len(cancellation_rows) == 1 and cancellation_rows[0]['kind'] == 'cancellation'
            assert prepare(cancellation_rows[0]) is not None
            assert complete(cancellation_rows[0]) == 't'

            # Unknown/partial-day facts are preserved, never expanded into date-only full closure.
            partial = fact('shortened_hours', starts_on='2026-10-01', ends_on='2026-10-05', starts_at='18:00', time_meaning='partial_day', message='10/1 저녁부터 10/5까지 휴무')
            partial_draft = command('draft', doc=document([partial]))
            assert partial_draft['facts'][0]['starts_at'] == '18:00' and partial_draft['facts'][0]['time_meaning'] == 'partial_day'
            unknown = command('draft', doc=document([fact(certainty='unknown', verified=False)]))
            reject(f"select public.notification_publication_command('preview','{unknown['announcement_id']}',1,null,'unknown-preview')", 'unverified_notification_fact')
            split = command('draft', doc=document([fact(time_meaning='last_order', ends_at='14:00'), fact(starts_on='2026-11-13', ends_on='2026-11-13',context_key='next-day')]))
            reject(f"select public.notification_publication_command('preview','{split['announcement_id']}',1,null,'split-preview')", 'split_required')
            incompatible = command('draft', doc=document([fact(), fact('event', starts_on='2026-11-13',ends_on='2026-11-13',message='다음 날 콜라보',registration_type='event',registration_id=EVENT,destination={'version':1,'action':'event_detail','event_id':EVENT})]))
            reject(f"select public.notification_publication_command('preview','{incompatible['announcement_id']}',1,null,'same-context-compound-split')", 'split_required')
            invalid_url = document([fact(destination={'version':1,'action':'external_url','url':'javascript:alert(1)'})])
            reject(f"select public.notification_publication_command('draft',null,0,{quoted(json.dumps(invalid_url))}::jsonb,'unsafe-url')", 'invalid_notification_url')
            # A standalone event with delivery history cannot be attached as a new announcement.
            sent_event = '30000000-0000-0000-0000-000000000002'
            sql(f"insert into public.shop_events(id,shop_id) values('{sent_event}','{SHOP}'); insert into public.event_notification_deliveries(event_id,user_id,registration_identifier,notification_type,status) values('{sent_event}','{A}','{NEW}','new_event','sent')")
            late_join = command('draft', doc=document([fact()]))
            reject(f"select public.link_notification_registration('{late_join['announcement_id']}',1,'event','{sent_event}',true)", 'standalone_event_correction_required')
            # Hold the first transaction until the competing operation is demonstrably
            # waiting on the shared advisory lock. Neither race uses timing as ordering.
            def locked_race(first, second):
                session = subprocess.Popen(psql, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
                try:
                    session.stdin.write("begin; set role service_role; " + first + ";\n\echo FIRST_LOCKED\n")
                    session.stdin.flush()
                    while session.stdout.readline().strip() != 'FIRST_LOCKED':
                        if session.poll() is not None:
                            raise AssertionError(session.stderr.read())
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        competing = executor.submit(sql, "set application_name='notification-race-waiter';" + second)
                        deadline = time.monotonic() + 5
                        while sql("select count(*) from pg_stat_activity where application_name='notification-race-waiter' and wait_event_type='Lock'", role=None) != '1':
                            if competing.done() or time.monotonic() > deadline:
                                raise AssertionError('Competing operation did not wait for the shared event lock')
                            time.sleep(0.01)
                        session.stdin.write("commit;\n\q\n")
                        session.stdin.flush()
                        session.wait(timeout=5)
                        return competing.result()
                finally:
                    if session.poll() is None:
                        session.kill()
                        session.wait(timeout=5)

            race_event = '30000000-0000-0000-0000-000000000003'
            sql(f"insert into public.shop_events(id,shop_id) values('{race_event}','{SHOP}')")
            race_draft = command('draft', doc=document([fact()]))
            linked_first = locked_race(
                f"select public.link_notification_registration('{race_draft['announcement_id']}',1,'event','{race_event}',true)",
                f"select public.claim_event_notification_delivery('{race_event}','{A}','{NEW}','new_event')")
            assert linked_first == 'f', 'Link-first blocks a stale standalone webhook claim'
            race_event2 = '30000000-0000-0000-0000-000000000004'
            sql(f"insert into public.shop_events(id,shop_id) values('{race_event2}','{SHOP}')")
            try:
                locked_race(
                    f"select public.claim_event_notification_delivery('{race_event2}','{A}','{NEW}','new_event')",
                    f"select public.link_notification_registration('{race_draft['announcement_id']}',1,'event','{race_event2}',true)")
                raise AssertionError('Claim-first standalone delivery was incorrectly linked')
            except RuntimeError as failure:
                assert 'standalone_event_correction_required' in str(failure)

            monthly = publish(document([fact(starts_on='2026-11-02',ends_on='2026-11-02'),fact(starts_on='2026-11-09',ends_on='2026-11-09')]))
            monthly_rows = claim()
            assert len(monthly_rows) == 2 and all(len(x['facts']) == 2 for x in monthly_rows), '같은 월간 공지는 기기당 한 발행'
            # Expired pre-send claim can be reclaimed, stale token cannot send.
            sql(f"update notification_private.deliveries set lease_until=now()-interval '1 second' where announcement_id='{monthly['announcement_id']}' and status='claimed'")
            reclaimed = claim()
            assert len(reclaimed) == len(monthly_rows)
            assert prepare(monthly_rows[0]) is None
            # Consent revocation before send cancels current work.
            save([], clear=True)
            assert all(prepare(item) is None for item in reclaimed)
            assert sql('select count(*) from public.event_reminders') == '1', '기존 이벤트 리마인더 자료 유지'
            print('PASS: 선택 보존·명시적 해제·기기 버전·검증/발행·교집합·정정·중복/lease·unknown·보안')
        finally:
            if started:
                run('pg_ctl','-D',str(data),'-m','immediate','-w','stop')


if __name__ == '__main__':
    main()
