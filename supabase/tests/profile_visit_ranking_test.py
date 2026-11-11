#!/usr/bin/env python3
"""임시 로컬 PostgreSQL에서 프로필 방문 순위 집계와 조회 권한을 검증한다."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    for command in ("initdb", "pg_ctl", "psql"):
        if shutil.which(command) is None:
            raise SystemExit(f"로컬 PostgreSQL 명령이 필요합니다: {command}")
    tests = Path(__file__).resolve().parent
    migrations = tests.parent / "migrations"
    sources = (
        tests / "fixtures/profile_visit_ranking.sql",
        migrations / "20261006004609_follow_profile_visibility.sql",
        migrations / "20261006012725_profile_summary_counts.sql",
        migrations / "20261111040746_profile_visit_ranking.sql",
        migrations / "20261111070213_profile_visit_ranking_shop_profile_image.sql",
        migrations / "20261111082802_profile_visit_ranking_ties.sql",
        tests / "profile_visit_ranking.sql",
    )

    def run(*command):
        return subprocess.run(command, check=True, capture_output=True, text=True)

    with tempfile.TemporaryDirectory(prefix="ramap-visits-", dir="/tmp") as temporary:
        root = Path(temporary)
        data = root / "data"
        started = False
        try:
            run("initdb", "-D", str(data), "-A", "trust", "-U", "postgres", "--no-locale", "--encoding=UTF8")
            run("pg_ctl", "-D", str(data), "-l", str(root / "postgres.log"),
                "-o", f"-k {root} -c listen_addresses=''", "-w", "start")
            started = True
            for source in sources:
                run("psql", "-X", "-h", str(root), "-U", "postgres", "-d", "postgres",
                    "-v", "ON_ERROR_STOP=1", "-f", str(source))
            print("PASS: 방문 순위, 동률과 최대 10개, 공개 매장 사진, 본인·타인·비회원·팔로워·차단·탈퇴 권한")
        except subprocess.CalledProcessError as error:
            print(error.stdout)
            print(error.stderr)
            raise SystemExit(error.returncode) from error
        finally:
            if started:
                run("pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop")


if __name__ == "__main__":
    main()
