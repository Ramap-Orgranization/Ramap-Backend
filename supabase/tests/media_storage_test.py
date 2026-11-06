#!/usr/bin/env python3
"""격리된 로컬 PostgreSQL에서 저장소 상태 전이와 권한 경계를 검증한다."""
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    for name in ('initdb', 'pg_ctl', 'psql'):
        if not shutil.which(name):
            raise SystemExit('로컬 PostgreSQL 명령이 필요합니다: ' + name)
    tests = Path(__file__).resolve().parent
    def run(*command):
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout
    with tempfile.TemporaryDirectory(prefix='ramap-media-', dir='/tmp') as temporary:
        root = Path(temporary)
        started = False
        try:
            run('initdb', '-D', str(root / 'data'), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8')
            run('pg_ctl', '-D', str(root / 'data'), '-l', str(root / 'postgres.log'), '-o', f"-k {root} -c listen_addresses=''", '-w', 'start')
            started = True
            for source in (tests / 'fixtures/media_storage.sql', tests.parent / 'migrations/20261101051329_firebase_media_storage.sql', *sorted((tests.parent / 'migrations').glob('*_preserve_empty_legacy_media.sql')), *sorted((tests.parent / 'migrations').glob('*_harden_media_rpc_grants.sql')), *sorted((tests.parent / 'migrations').glob('*_scope_media_settings_update.sql')), tests / 'media_storage.sql', *sorted((tests.parent / 'migrations').glob('*_r2_media_storage.sql')), tests / 'r2_media_storage.sql', tests / 'fixtures/gcs_retirement.sql', *sorted((tests.parent / 'migrations').glob('*_remove_gcs_media_runtime.sql')), tests / 'r2_only_media_storage.sql', *sorted((tests.parent / 'migrations').glob('*_scope_media_copy_to_used_photos.sql')), tests / 'used_media_copy.sql', *sorted((tests.parent / 'migrations').glob('*_optimize_used_photo_inventory.sql')), tests / 'used_media_copy.sql', *sorted((tests.parent / 'migrations').glob('*_fast_path_media_copy_eligibility.sql')), tests / 'used_media_copy.sql', tests / 'fixtures/retired_media_cleanup.sql', *sorted((tests.parent / 'migrations').glob('*_preserve_retired_media_cleanup.sql')), tests / 'retired_media_cleanup.sql'):
                run('psql', '-X', '-h', str(root), '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-f', str(source))
            print('PASS: 은퇴 저장소 실제 삭제 확인·계정별 claim·lease·재시도·권한, 종료 이벤트·미참조 제외, 미래·공유·신고 증거 유지, R2 v1/v2 호환·복사 스냅샷·삭제 fence·GCS 전용 inventory·ETag 분리, 미확정·타인 사진 거절, 구버전 복사, 확정 재시도, 신고 보존, 삭제 lease, 백필 부활 차단, RPC 권한')
        except subprocess.CalledProcessError as error:
            print(error.stdout)
            print(error.stderr)
            raise SystemExit(error.returncode) from error
        finally:
            if started:
                run('pg_ctl', '-D', str(root / 'data'), '-m', 'immediate', '-w', 'stop')


if __name__ == '__main__':
    main()
