#!/usr/bin/env python3
"""새 migration만 격리 로컬 PostgreSQL에 적용하여 알림 설정 계약을 검증한다."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ACCOUNT_A = '00000000-0000-0000-0000-000000000001'
ACCOUNT_B = '00000000-0000-0000-0000-000000000002'
SHOP = '10000000-0000-0000-0000-000000000001'
HIDDEN_SHOP = '10000000-0000-0000-0000-000000000002'


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--migration', type=Path, required=True)
    args = parser.parse_args()
    for command in ('initdb', 'pg_ctl', 'psql'):
        if shutil.which(command) is None:
            raise SystemExit(f'로컬 PostgreSQL 명령이 필요합니다: {command}')
    fixture = Path(__file__).resolve().parent / 'fixtures/shop_notification_settings.sql'
    with tempfile.TemporaryDirectory(prefix='ramap-notifications-', dir='/tmp') as temporary:
        root = Path(temporary)
        data = root / 'data'
        started = False
        try:
            run('initdb', '-D', str(data), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8')
            run('pg_ctl', '-D', str(data), '-l', str(root / 'postgres.log'), '-o',
                f"-k {root} -c listen_addresses=''", '-w', 'start')
            started = True
            command = ('psql', '-X', '-qAt', '-h', str(root), '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1')
            for source in (fixture, args.migration.resolve()):
                run(*command, '-f', str(source))

            def sql(query, account=ACCOUNT_A, role='authenticated'):
                prefix = '' if role is None else f"set role {role}; set request.jwt.claim.sub='{account or ''}';"
                return run(*command, '-c', prefix + query)

            def snapshot(account=ACCOUNT_A, shop=SHOP):
                return json.loads(sql(f"select public.fetch_shop_notification_settings('{shop}','{account}');", account))

            def revision():
                return snapshot()['catalog_revision']

            def save(ids, account=ACCOUNT_A, version=None):
                selected = 'array[' + ','.join("'" + item + "'" for item in ids) + ']::text[]'
                version = revision() if version is None else version
                return json.loads(sql(f"select public.save_shop_notification_settings('{SHOP}','{account}',{version},{selected});", account))

            def reject(query, marker, account=ACCOUNT_A, role='authenticated'):
                try:
                    sql(query, account, role)
                except RuntimeError as error:
                    assert marker in str(error), str(error)
                    return
                raise AssertionError(f'거절되지 않음: {query}')

            initial = snapshot()
            assert initial['account_id'] == ACCOUNT_A and initial['shop_id'] == SHOP
            assert initial['selected_type_ids'] == ['event'], '기존 이벤트 유지 및 신규 기본 OFF'
            assert len(initial['types']) == 6
            assert [x['display_order'] for x in initial['types']] == sorted(x['display_order'] for x in initial['types'])
            assert save(['event', 'early_closing', 'early_closing'])['selected_type_ids'] == ['event', 'early_closing']
            assert sql('select count(*) from public.shop_operating_notification_subscriptions;') == '1', '중복 방지'
            assert snapshot(ACCOUNT_B)['selected_type_ids'] == [], '계정 B 격리'
            assert sql('select count(*) from public.shop_operating_notification_subscriptions;', ACCOUNT_B) == '0'
            reject(f"insert into public.shop_operating_notification_subscriptions(user_id,shop_id,type_id) values ('{ACCOUNT_A}','{SHOP}','delayed_opening')", 'row-level security', ACCOUNT_B)
            sql(f"delete from public.shop_operating_notification_subscriptions where user_id='{ACCOUNT_A}';", ACCOUNT_B)
            assert snapshot()['selected_type_ids'] == ['event', 'early_closing']
            reject(f"select public.fetch_shop_notification_settings('{SHOP}','{ACCOUNT_A}')", 'permission denied', role='anon')
            reject(f"select public.fetch_shop_notification_settings('{SHOP}','{ACCOUNT_A}')", 'authentication_required', account=None)
            reject(f"select public.fetch_shop_notification_settings('{SHOP}','{ACCOUNT_B}')", 'notification_account_mismatch')
            reject(f"select public.fetch_shop_notification_settings('{HIDDEN_SHOP}','{ACCOUNT_A}')", 'notification_shop_unavailable')
            reject(f"select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',0,array['event'])", 'notification_catalog_revision_mismatch')
            reject(f"select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{revision()},array['delayed_opening','unknown'])", 'notification_type_unavailable')
            reject(f"select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{revision()},array[null]::text[])", 'notification_type_unavailable')
            reject(f"select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_B}',{revision()},array['event'])", 'notification_account_mismatch')
            reject(f"select public.clear_shop_notification_settings('{SHOP}','{ACCOUNT_B}')", 'notification_account_mismatch')
            reject(f"select public.fetch_subscribed_shop_ids('{ACCOUNT_B}')", 'notification_account_mismatch')
            reject(f"select public.save_shop_notification_settings('{HIDDEN_SHOP}','{ACCOUNT_A}',{revision()},array['event'])", 'notification_shop_unavailable')
            reject(f"select public.clear_shop_notification_settings('{HIDDEN_SHOP}','{ACCOUNT_A}')", 'notification_shop_unavailable')
            assert snapshot()['selected_type_ids'] == ['event', 'early_closing'], '검증 실패 시 부분 저장 금지'
            reject("update public.shop_notification_catalog set title='변경'", 'permission denied')
            reject('update shop_notification_private.catalog_revision set revision=99', 'permission denied')
            reject('select shop_notification_private.catalog_changed()', 'permission denied')
            sql(f"select public.set_shop_event_notification('{SHOP}',false)")
            assert snapshot()['selected_type_ids'] == ['early_closing'], 'legacy 이벤트 변경은 운영 선택 유지'
            assert json.loads(sql(f"select public.fetch_subscribed_shop_ids('{ACCOUNT_A}')")) == [SHOP], '운영 단독 매장 집계'
            save(['event', 'delayed_opening'])
            before = revision()
            sql("update public.shop_notification_catalog set title='지연 안내',display_order=1 where id='delayed_opening'", role=None)
            changed = snapshot()
            assert changed['catalog_revision'] > before
            assert changed['types'][0]['id'] == 'delayed_opening' and changed['types'][0]['title'] == '지연 안내'
            sql("insert into public.shop_notification_catalog(id,title,display_order) values ('future_type','서버 추가',5)", role=None)
            assert 'future_type' not in snapshot()['selected_type_ids']
            assert any(x['id'] == 'future_type' for x in snapshot()['types'])
            assert 'future_type' in save(['future_type'])['selected_type_ids'], '미지의 서버 유형 저장'
            sql("update public.shop_notification_catalog set is_active=false where id='future_type'", role=None)
            assert snapshot()['selected_type_ids'] == []
            reject(f"select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{revision()},array['event','future_type'])", 'notification_type_unavailable')
            sql("update public.shop_notification_catalog set is_active=true where id='future_type'", role=None)
            assert snapshot()['selected_type_ids'] == [], '재활성화 자동 재구독 금지'
            save(['future_type'])
            sql("update public.shop_notification_catalog set is_visible=false where id='future_type'", role=None)
            assert 'future_type' not in [x['id'] for x in snapshot()['types']]
            sql("update public.shop_notification_catalog set is_visible=true where id='future_type'", role=None)
            assert snapshot()['selected_type_ids'] == [], '다시 노출해도 자동 재구독 금지'
            save(['event'])
            sql("update public.shop_notification_catalog set is_visible=false where id='event'", role=None)
            assert json.loads(sql(f"select public.fetch_subscribed_shop_ids('{ACCOUNT_A}')")) == []
            assert sql('select count(*) from public.shop_event_notification_subscriptions') == '1', 'legacy 원본 보존'
            sql("update public.shop_notification_catalog set is_visible=true where id='event'", role=None)
            reject("update public.shop_notification_catalog set id='renamed' where id='event'", 'notification_type_id_is_immutable', role=None)
            reject("delete from public.shop_notification_catalog where id='event'", 'legacy_event_type_cannot_be_deleted', role=None)
            save(['event', 'shortened_hours'], ACCOUNT_B)
            save(['event', 'early_closing'])
            cleared = json.loads(sql(f"select public.clear_shop_notification_settings('{SHOP}','{ACCOUNT_A}')"))
            assert cleared['selected_type_ids'] == []
            assert snapshot(ACCOUNT_B)['selected_type_ids'] == ['event', 'shortened_hours']
            assert sql('select count(*) from public.event_reminders', role=None) == '1', '개별 이벤트 리마인더 유지'

            def open_session(name, preparation):
                process = subprocess.Popen(
                    (*command, '-v', 'VERBOSITY=verbose'), stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
                )
                process.stdin.write(
                    f"set application_name='{name}'; set statement_timeout='5s'; "
                    + preparation + "; select 'READY';\n"
                )
                process.stdin.flush()
                for line in process.stdout:
                    if line.strip() == 'READY':
                        return process
                raise AssertionError(process.stderr.read())

            def finish_session(process, query, expected_error=None, expected_message='notification_selection_busy_retry'):
                output, error = process.communicate(query + ';\n', timeout=8)
                if expected_error is None:
                    assert process.returncode == 0, output + error
                else:
                    assert process.returncode != 0 and expected_error in error, output + error
                    assert expected_message in error, error
                    assert 'deadlock detected' not in error and 'statement timeout' not in error, error
                return output

            def wait_for_tuple_contention(name='notification-rpc-contended'):
                for _ in range(100):
                    if sql(f"select count(*) from pg_stat_activity where application_name='{name}' and wait_event_type='Lock'", role=None) == '1':
                        return
                    time.sleep(0.02)
                raise AssertionError('RPC의 tuple 잠금 대기를 확인하지 못함')

            # A transaction is held open after its save; the second save must wait.
            version = revision()
            with ThreadPoolExecutor(max_workers=2) as executor:
                first = executor.submit(sql, f"begin; select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{version},array['event','early_closing']); select pg_sleep(1); commit;")
                for _ in range(100):
                    if sql("select count(*) from pg_stat_activity where wait_event='PgSleep'", role=None) == '1':
                        break
                    time.sleep(0.02)
                else:
                    raise AssertionError('첫 저장의 잠금 획득을 확인하지 못함')
                second = executor.submit(save, ['shortened_hours'], ACCOUNT_A, version)
                first.result()
                assert second.result()['selected_type_ids'] == ['shortened_hours']
            assert snapshot()['selected_type_ids'] == ['shortened_hours'], '동시 저장은 전체 선택을 직렬화'
            assert sql('select count(*) from public.shop_operating_notification_subscriptions') == '1'
            catalog_holder = open_session('notification-catalog-reader', f"begin; set local role authenticated; set local request.jwt.claim.sub='{ACCOUNT_A}'; select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{version},array['early_closing'])")
            catalog_editor = open_session('notification-catalog-editor', 'begin')
            try:
                finish_session(catalog_editor, "update public.shop_notification_catalog set is_active=false where id='early_closing'; commit", '55P03', 'notification_catalog_busy_retry')
                assert sql('select revision from shop_notification_private.catalog_revision', role=None) == str(version), '실패한 카탈로그 변경은 revision 유지'
                assert sql("select is_active from public.shop_notification_catalog where id='early_closing'", role=None) == 't'
                assert sql(f"select type_id from public.shop_operating_notification_subscriptions where user_id='{ACCOUNT_A}'", role=None) == 'shortened_hours', '카탈로그 실패 중 기존 committed 구독 유지'
                finish_session(catalog_holder, 'commit')
            finally:
                for process in (catalog_holder, catalog_editor):
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
            assert snapshot()['selected_type_ids'] == ['early_closing']
            sql("update public.shop_notification_catalog set is_active=false where id='early_closing'", role=None)
            assert snapshot()['selected_type_ids'] == [], '저장 완료 후 카탈로그 재시도는 구독을 정리'
            assert revision() == version + 1
            reject(f"select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{version},array['shortened_hours'])", 'notification_catalog_revision_mismatch')
            # Model DELETE's tuple-first ordering explicitly, then run the actual
            # DELETE as authenticated. The RPC holds the opposite advisory lock.
            save(['event', 'shortened_hours'])
            version = revision()
            direct = open_session('notification-direct-delete', f"begin; select type_id from public.shop_operating_notification_subscriptions where user_id='{ACCOUNT_A}' and shop_id='{SHOP}' for update; set local role authenticated; set local request.jwt.claim.sub='{ACCOUNT_A}'")
            rpc = open_session('notification-rpc-contended', f"begin; set local role authenticated; set local request.jwt.claim.sub='{ACCOUNT_A}'; select public.fetch_shop_notification_settings('{SHOP}','{ACCOUNT_A}')")
            try:
                rpc.stdin.write(f"select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{version},array['delayed_opening']); commit;\n")
                rpc.stdin.flush()
                wait_for_tuple_contention()
                finish_session(direct, f"delete from public.shop_operating_notification_subscriptions where user_id='{ACCOUNT_A}' and shop_id='{SHOP}'; commit", '55P03')
                finish_session(rpc, '')
            finally:
                for process in (direct, rpc):
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
            assert snapshot()['selected_type_ids'] == ['delayed_opening'], '직접 DELETE 충돌 후 정상 RPC가 전체 설정 저장'
            sql(f"delete from public.shop_operating_notification_subscriptions where shop_id='{SHOP}'")
            assert snapshot()['selected_type_ids'] == [], '55P03 뒤 전체 트랜잭션 재시도 성공'

            second_shop = '10000000-0000-0000-0000-000000000003'
            sql(f"insert into public.ramen_shops(id,is_visible) values ('{second_shop}',true)", role=None)
            save(['event', 'shortened_hours'])
            holder = open_session('notification-multirow-holder', f"begin; set local role authenticated; set local request.jwt.claim.sub='{ACCOUNT_A}'; select public.fetch_shop_notification_settings('{second_shop}','{ACCOUNT_A}')")
            insert_rows = f"insert into public.shop_operating_notification_subscriptions(user_id,shop_id,type_id) values ('{ACCOUNT_A}','{SHOP}','delayed_opening'),('{ACCOUNT_A}','{second_shop}','delayed_opening')"
            contender = open_session('notification-multirow-contender', f"begin; set local role authenticated; set local request.jwt.claim.sub='{ACCOUNT_A}'; delete from public.shop_event_notification_subscriptions where shop_id='{SHOP}'")
            try:
                finish_session(contender, insert_rows + '; commit', '55P03')
                finish_session(holder, 'commit')
            finally:
                for process in (holder, contender):
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
            assert snapshot()['selected_type_ids'] == ['event', 'shortened_hours'], '다중 행 실패는 앞선 이벤트 삭제와 운영 삽입도 롤백'
            assert json.loads(sql(f"select public.fetch_shop_notification_settings('{second_shop}','{ACCOUNT_A}')"))['selected_type_ids'] == []
            sql('begin; ' + insert_rows + '; commit')
            assert snapshot()['selected_type_ids'] == ['delayed_opening', 'event', 'shortened_hours'], '경합 해제 후 다중 행 재시도 성공'
            assert json.loads(sql(f"select public.fetch_shop_notification_settings('{second_shop}','{ACCOUNT_A}')"))['selected_type_ids'] == ['delayed_opening']
            sql(f"select public.clear_shop_notification_settings('{SHOP}','{ACCOUNT_A}'); select public.clear_shop_notification_settings('{second_shop}','{ACCOUNT_A}')")
            assert json.loads(sql(f"select public.fetch_subscribed_shop_ids('{ACCOUNT_A}')")) == [], '재시도 뒤 전체 해제와 집계 유지'
            # The mixed transaction owns shared catalog + user/shop locks.
            # A waiting RPC owns a second shared catalog lock before waiting on
            # that user/shop lock, so a blocking exclusive upgrade would cycle.
            save(['event', 'shortened_hours'])
            version = revision()
            mixed = open_session('notification-mixed-holder', f"begin; set local request.jwt.claim.sub='{ACCOUNT_A}'; select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{version},array['delayed_opening'])")
            waiting = open_session('notification-mixed-waiter', f"begin; set local role authenticated; set local request.jwt.claim.sub='{ACCOUNT_A}'")
            try:
                waiting.stdin.write(f"select public.fetch_shop_notification_settings('{SHOP}','{ACCOUNT_A}'); commit;\n")
                waiting.stdin.flush()
                wait_for_tuple_contention('notification-mixed-waiter')
                assert sql("select wait_event from pg_stat_activity where application_name='notification-mixed-waiter'", role=None) == 'advisory'
                finish_session(mixed, "update public.shop_notification_catalog set is_active=false where id='delayed_opening'; commit", '55P03', 'notification_catalog_busy_retry')
                observed = json.loads(finish_session(waiting, '').strip())
            finally:
                for process in (mixed, waiting):
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
            assert observed['selected_type_ids'] == ['event', 'shortened_hours'], '혼합 트랜잭션 실패는 앞선 이벤트 삭제와 운영 변경도 롤백'
            assert observed['catalog_revision'] == version and revision() == version
            assert sql("select is_active from public.shop_notification_catalog where id='delayed_opening'", role=None) == 't'
            sql(f"begin; set local request.jwt.claim.sub='{ACCOUNT_A}'; select public.save_shop_notification_settings('{SHOP}','{ACCOUNT_A}',{version},array['delayed_opening']); update public.shop_notification_catalog set is_active=false where id='delayed_opening'; commit", role=None)
            assert snapshot()['selected_type_ids'] == [], '대기 RPC 완료 후 혼합 트랜잭션 재시도와 비활성화 정리 성공'
            assert revision() == version + 1
            assert sql('select count(*) from public.shop_event_notification_subscriptions') == '0'
            assert sql("select is_active from public.shop_notification_catalog where id='delayed_opening'", role=None) == 'f'
            print('PASS: legacy 유지, 동적 카탈로그, 원자적 저장·전체 해제, RLS·인증·revision·유효성, 비활성화, RPC·카탈로그·직접 DELETE·다중 행·혼합 트랜잭션 경합')
        finally:
            if started:
                run('pg_ctl', '-D', str(data), '-m', 'immediate', '-w', 'stop')


if __name__ == '__main__':
    main()
