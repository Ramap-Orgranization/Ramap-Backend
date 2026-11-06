#!/usr/bin/env python3
"""임시 로컬 PostgreSQL에서 공지 유형 전환과 레거시 휴무 보존을 검증한다."""
import argparse
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migration", type=Path, required=True)
    args = parser.parse_args()
    for command in ("initdb", "pg_ctl", "psql"):
        if not shutil.which(command):
            raise SystemExit(f"Required local command: {command}")
    with tempfile.TemporaryDirectory(prefix="ramap-notice-types-") as directory:
        folder = Path(directory)
        database = folder / "db"
        subprocess.run(["initdb", "-D", str(database), "--auth=trust", "--no-locale", "--encoding=UTF8"], check=True, capture_output=True)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        subprocess.run(["pg_ctl", "-D", str(database), "-l", str(folder / "server.log"), "-o", f"-F -p {port} -h 127.0.0.1 -k {directory}", "-w", "start"], check=True, capture_output=True)

        def query(sql):
            result = subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1", "-p", str(port), "-d", "postgres"], input=sql, text=True, capture_output=True)
            if result.returncode:
                raise AssertionError(result.stderr)

        try:
            query("""
                create table public.ramen_shops (id uuid primary key default gen_random_uuid());
                create table public.instagram_posts_raw (id uuid primary key default gen_random_uuid());
                insert into public.ramen_shops default values;
                insert into public.instagram_posts_raw default values;
                create table public.shop_operating_notices (
                    id uuid primary key default gen_random_uuid(),
                    shop_id uuid not null references public.ramen_shops(id) on delete cascade,
                    raw_post_id uuid not null references public.instagram_posts_raw(id) on delete cascade,
                    notice_type text not null, description text, notice_date date not null, end_date date,
                    start_time time, end_time time, source_url text not null,
                    created_at timestamptz default now(), updated_at timestamptz default now(),
                    schedule_override jsonb, manually_released_at timestamptz,
                    ocr_text text, confidence numeric, review_note text,
                    constraint shop_operating_notices_type_check check (notice_type in ('operating_notice','full_close','early_close','late_opening')),
                    constraint shop_operating_notices_source_url_check check (length(trim(source_url)) > 0),
                    constraint shop_operating_notices_confidence_check check (confidence is null or confidence between 0 and 1)
                );
            """)
            query((args.migration.parent / "20261003032631_add_operating_notice_daily_schedules.sql").read_text())
            query("""
                insert into public.shop_operating_notices (shop_id,raw_post_id,notice_type,description,notice_date,end_date,source_url,daily_schedules,schedule_override,end_time)
                select s.id,r.id,v.kind,'합성 원문',v.first_day::date,v.last_day::date,v.source,v.days::jsonb,v.override::jsonb,v.closing::time
                from public.ramen_shops s cross join public.instagram_posts_raw r cross join (values
                    ('operating_notice','2099-10-01','2099-10-31','calendar','[{"date":"2099-10-14","closed":true,"schedule_override":null},{"date":"2099-10-17","closed":false,"schedule_override":null},{"date":"2099-10-21","closed":true,"schedule_override":null}]',null,null),
                    ('full_close','2099-10-14','2099-10-14','calendar','[]',null,null),
                    ('operating_notice','2099-10-22','2099-10-22','closed-override','[]','{"closed":true}',null),
                    ('operating_notice','2099-10-23','2099-10-23','hours-override','[]','{"closed":false,"open":"11:00","close":"18:00"}',null),
                    ('late_opening','2099-10-24','2099-10-24','delay','[]',null,null),
                    ('early_close','2099-10-25','2099-10-25','missing-time','[]',null,null),
                    ('early_close','2099-10-26','2099-10-26','confirmed-time','[]',null,'15:00')
                ) v(kind,first_day,last_day,source,days,override,closing);
                alter table public.shop_operating_notices add constraint shop_operating_notices_early_close_end_time_check check (notice_type <> 'early_close' or end_time is not null) not valid;
                alter table public.shop_operating_notices add constraint shop_operating_notices_manual_release_type_check check (manually_released_at is null or notice_type = 'late_opening') not valid;
                alter table public.shop_operating_notices add constraint shop_operating_notices_schedule_override_type_check check (schedule_override is null or (notice_type = 'operating_notice' and jsonb_typeof(schedule_override) = 'object')) not valid;
                create schema operating_notice_private;
                alter table public.shop_operating_notices set schema operating_notice_private;
                create view public.shop_operating_notices with (security_invoker=true) as
                select id,shop_id,notice_type,description,notice_date,start_time,end_time,source_url,created_at,updated_at,end_date,schedule_override,manually_released_at,daily_schedules from operating_notice_private.shop_operating_notices;
            """)
            query(args.migration.read_text())
            query("""
                do $$ begin
                    assert (select count(*) from operating_notice_private.shop_operating_notices) = 9, '원본과 중복 없는 휴무 사본을 보존한다';
                    assert (select count(*) from public.shop_operating_notices) = 4, '두 공지 유형과 확인된 시각만 공개한다';
                    assert (select count(*) from public.shop_operating_notices where source_url='calendar') = 2, '달력의 실제 휴무일만 공개한다';
                    assert not exists(select 1 from public.shop_operating_notices where source_url='calendar' and notice_date='2099-10-17'), '정상영업일은 휴무로 만들지 않는다';
                    assert not exists(select 1 from public.shop_operating_notices where source_url='calendar' and notice_date<>end_date), '구버전도 월 전체 휴무로 해석하지 않는다';
                    assert (select 'security_invoker=true'=any(reloptions) from pg_class where oid='public.shop_operating_notices'::regclass), '공개 뷰의 권한 경계를 유지한다';
                    begin
                        insert into operating_notice_private.shop_operating_notices (shop_id,raw_post_id,notice_type,notice_date,end_date,source_url)
                        select s.id,r.id,'operating_notice','2099-11-01','2099-11-01','rejected' from public.ramen_shops s cross join public.instagram_posts_raw r;
                        raise exception '제거한 유형이 저장됐다';
                    exception when check_violation then null; end;
                    begin
                        insert into operating_notice_private.shop_operating_notices (shop_id,raw_post_id,notice_type,notice_date,end_date,source_url)
                        select s.id,r.id,'early_close','2099-11-01','2099-11-01','rejected' from public.ramen_shops s cross join public.instagram_posts_raw r;
                        raise exception '시각 없는 조기 마감이 저장됐다';
                    exception when check_violation then null; end;
                    insert into operating_notice_private.shop_operating_notices (shop_id,raw_post_id,notice_type,notice_date,end_date,source_url,end_time)
                    select s.id,r.id,'early_close','2099-11-01','2099-11-01','valid','15:00' from public.ramen_shops s cross join public.instagram_posts_raw r;
                    assert exists(select 1 from public.shop_operating_notices where source_url='valid' and end_time='15:00'), '확인된 조기 마감은 공개한다';
                end $$;
            """)
            print("PASS: legacy preservation, calendar dates, two types, closing time, public view permissions")
        finally:
            subprocess.run(["pg_ctl", "-D", str(database), "-m", "immediate", "-w", "stop"], check=True, capture_output=True)


if __name__ == "__main__":
    main()
