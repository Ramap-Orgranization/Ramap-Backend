#!/usr/bin/env python3
"""임시 로컬 PostgreSQL에서 리뷰 삭제 후 방문 차수와 모든 조회 경로를 검증한다."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--projection-sql", type=Path, help="회귀 재현용 이전 조회 함수 SQL")
    args = parser.parse_args()
    for command in ("initdb", "pg_ctl", "psql"):
        if shutil.which(command) is None:
            parser.error(f"로컬 PostgreSQL 명령이 필요합니다: {command}")
    tests = Path(__file__).resolve().parent
    migration = tests.parent / "migrations/20261031152722_count_remaining_review_visits.sql"

    def run(*command):
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout

    # A short, private socket path avoids macOS Unix socket path limits.
    with tempfile.TemporaryDirectory(prefix="ramap-visits-", dir="/tmp") as temporary:
        root = Path(temporary)
        data = root / "data"
        started = False
        try:
            run("initdb", "-D", str(data), "-A", "trust", "-U", "postgres", "--no-locale", "--encoding=UTF8")
            run("pg_ctl", "-D", str(data), "-l", str(root / "postgres.log"),
                "-o", f"-k {root} -c listen_addresses=''", "-w", "start")
            started = True
            for source in (tests / "fixtures/review_visit_numbers.sql",
                           tests.parent / "migrations/20261026080230_review_feed_filters.sql",
                           tests.parent / "migrations/20261026105129_review_feed_filter_target_presence.sql",
                           args.projection_sql or migration,
                           tests / "review_visit_numbers.sql"):
                run("psql", "-X", "-h", str(root), "-U", "postgres", "-d", "postgres",
                    "-v", "ON_ERROR_STOP=1", "-f", str(source))
            print("PASS: 반복 작성·삭제, 기존 누적 번호, 비공개·검수 상태, 작성자·매장 분리, 페이지, 조회 권한")
        except subprocess.CalledProcessError as error:
            print(error.stdout)
            print(error.stderr)
            raise SystemExit(error.returncode) from error
        finally:
            if started:
                run("pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop")


if __name__ == "__main__":
    main()
