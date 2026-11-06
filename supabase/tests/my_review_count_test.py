#!/usr/bin/env python3
"""임시 로컬 PostgreSQL에서 본인 리뷰 개수와 조회 권한을 검증한다."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    for command in ("initdb", "pg_ctl", "psql"):
        if shutil.which(command) is None:
            raise SystemExit(f"로컬 PostgreSQL 명령이 필요합니다: {command}")
    tests = Path(__file__).resolve().parent
    migration = tests.parent / "migrations/20261103081844_my_review_count.sql"

    def run(*command):
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout

    with tempfile.TemporaryDirectory(prefix="ramap-count-", dir="/tmp") as temporary:
        root = Path(temporary)
        data = root / "data"
        started = False
        try:
            run("initdb", "-D", str(data), "-A", "trust", "-U", "postgres", "--no-locale", "--encoding=UTF8")
            run("pg_ctl", "-D", str(data), "-l", str(root / "postgres.log"),
                "-o", f"-k {root} -c listen_addresses=''", "-w", "start")
            started = True
            for source in (tests / "fixtures/my_review_count.sql", migration, tests / "my_review_count.sql"):
                run("psql", "-X", "-h", str(root), "-U", "postgres", "-d", "postgres",
                    "-v", "ON_ERROR_STOP=1", "-f", str(source))
            print("PASS: 본인 리뷰 개수, 빈 목록, 계정 분리, 비회원·세션 없음·탈퇴 거절")
        except subprocess.CalledProcessError as error:
            print(error.stdout)
            print(error.stderr)
            raise SystemExit(error.returncode) from error
        finally:
            if started:
                run("pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop")


if __name__ == "__main__":
    main()
