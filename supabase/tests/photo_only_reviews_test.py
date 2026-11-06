#!/usr/bin/env python3
"""임시 PostgreSQL에서 사진 전용 리뷰와 기존 저장 경계를 검증한다."""

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

    def run(*command):
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout

    with tempfile.TemporaryDirectory(prefix="ramap-photo-review-", dir="/tmp") as temporary:
        root = Path(temporary)
        started = False
        try:
            run("initdb", "-D", str(root / "data"), "-A", "trust", "-U", "postgres", "--no-locale", "--encoding=UTF8")
            run("pg_ctl", "-D", str(root / "data"), "-l", str(root / "postgres.log"),
                "-o", f"-k {root} -c listen_addresses=''", "-w", "start")
            started = True
            psql = ("psql", "-X", "-h", str(root), "-U", "postgres", "-v", "ON_ERROR_STOP=1")
            run(*psql, "-f", str(tests / "fixtures/media_storage.sql"))
            run(*psql, "-c", """
                alter table public.ramen_shops add column name text;
                alter table public.public_profiles add column is_public boolean default true;
                alter table public.shop_reviews add column created_at timestamptz default now(),
                    add column moderation_note text,
                    add constraint shop_reviews_body_character_length
                        check (body = btrim(body) and char_length(body) between 5 and 100);
                create table public.review_likes(review_id uuid);
                drop schema review_submission_private cascade;
                create schema extensions;
                create extension pgcrypto with schema extensions;
            """)
            for source in (
                migrations / "20261012151044_review_mutation_receipts_v2.sql",
                migrations / "20261012225457_protect_review_submission_retries.sql",
                migrations / "20261101051329_firebase_media_storage.sql",
            ):
                run(*psql, "-f", str(source))
            run(*psql, "-c", """
                revoke all on function public.submit_shop_review(uuid,text,text[],boolean),
                    public.update_shop_review(uuid,text,text[],boolean) from public,anon;
                grant execute on function public.submit_shop_review(uuid,text,text[],boolean),
                    public.update_shop_review(uuid,text,text[],boolean) to authenticated;
            """)
            run(*psql, "-f", str(migrations / "20261102232626_allow_photo_only_reviews.sql"))
            run(*psql, "-f", str(tests / "photo_only_reviews.sql"))
            print("PASS: 이전 사진 전용 리뷰 정책의 본문·사진 경계, 재전송, 권한")
            run(*psql, "-f", str(tests / "fixtures/require_review_body.sql"))
            run(*psql, "-f", str(migrations / "20261105231723_require_review_body.sql"))
            run(*psql, "-f", str(tests / "require_review_body.sql"))
            print("PASS: v1/v2 작성·수정 본문 최소 5자, 기존 사진 전용 리뷰 보존")
        except subprocess.CalledProcessError as error:
            print(error.stdout)
            print(error.stderr)
            raise SystemExit(error.returncode) from error
        finally:
            if started:
                run("pg_ctl", "-D", str(root / "data"), "-m", "immediate", "-w", "stop")


if __name__ == "__main__":
    main()
