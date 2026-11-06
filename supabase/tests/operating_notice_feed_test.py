#!/usr/bin/env python3
"""임시 로컬 PostgreSQL에서 세 유형 feed와 공개 역할 경계를 검증한다."""
import argparse
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migration", type=Path, required=True)
    parser.add_argument("--followup-migration", type=Path, action="append", default=[])
    parser.add_argument("--without-regions", action="store_true")
    parser.add_argument("--normalize-descriptions", action="store_true")
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
                create role anon;
                create role authenticated;
                create schema operating_notice_private;
                create table public.ramen_shops (
                    id uuid primary key default gen_random_uuid(), name text, address text,
                    lat numeric default 37, lng numeric default 127, is_visible boolean default true,
                    kakao_place_url text, naver_place_url text, instagram_url text, instagram_profile_image_path text,
                    menu_category_ids text[], created_at timestamptz default now(), updated_at timestamptz default now(),
                    business_hours_weekly jsonb, business_hours_break_times jsonb, business_hours_last_orders jsonb,
                    business_hours_notice text, business_hours_notice_type text
                );
                create table operating_notice_private.shop_operating_notices (
                    id uuid primary key default gen_random_uuid(), shop_id uuid references public.ramen_shops(id),
                    notice_type text not null, description text, notice_date date not null, end_date date,
                    start_time time, end_time time, source_url text, created_at timestamptz default now(), updated_at timestamptz default now(),
                    schedule_override jsonb, manually_released_at timestamptz, daily_schedules jsonb default '[]',
                    ocr_text text, confidence numeric, review_note text
                );
                insert into public.ramen_shops (name,address,is_visible) values
                    ('서울매장','서울특별시 마포구 합정동',true),
                    ('세종매장','세종특별자치시 한누리대로 1',true),
                    ('알수없는매장','해외 1',true),
                    ('숨김매장','경기 수원시 권선동',false);
                insert into operating_notice_private.shop_operating_notices (shop_id,notice_type,notice_date,end_date,end_time,description,ocr_text)
                    select id,'early_close','2099-10-18','2099-10-18','14:00','공개원문','비공개OCR' from public.ramen_shops;
                insert into operating_notice_private.shop_operating_notices (shop_id,notice_type,notice_date,end_date)
                    select id,'operating_notice','2099-10-18',null from public.ramen_shops limit 1;
                alter table operating_notice_private.shop_operating_notices
                    add constraint shop_operating_notices_type_check check(notice_type in ('full_close','early_close')) not valid,
                    add constraint shop_operating_notices_supported_closure_check check(notice_type in ('full_close','early_close')) not valid;
                create view public.shop_operating_notices with (security_invoker=true) as
                    select id,shop_id,notice_type,description,notice_date,start_time,end_time,source_url,created_at,updated_at,end_date,schedule_override,manually_released_at,daily_schedules
                    from operating_notice_private.shop_operating_notices where notice_type in ('full_close','early_close');
                alter table operating_notice_private.shop_operating_notices enable row level security;
                create policy notice_public_read on operating_notice_private.shop_operating_notices for select to anon,authenticated using(true);
                alter table public.ramen_shops enable row level security;
                create policy visible_shop_read on public.ramen_shops for select to anon,authenticated using(is_visible);
                grant usage on schema public,operating_notice_private to anon,authenticated;
                grant select on public.ramen_shops,public.shop_operating_notices,operating_notice_private.shop_operating_notices to anon,authenticated;
            """)
            query(args.migration.read_text())
            if args.followup_migration:
                for migration in args.followup_migration:
                    query(migration.read_text())
                query("""
                    set role anon;
                    do $$ begin
                        assert not exists (
                            select 1 from jsonb_array_elements(public.fetch_operating_notice_feed('2099-10-18')->'items') item
                            where item->'shop' ? 'address'
                        ), '목록 API는 표시용 주소를 반환하지 않음';
                    end $$;
                    reset role;
                """)
            query("""
                do $$ begin
                    assert (select count(*) from operating_notice_private.shop_operating_notices)=5, '기존 원본 보존';
                    assert exists(select 1 from operating_notice_private.shop_operating_notices where notice_type='operating_notice'), 'legacy 보존';
                    insert into operating_notice_private.shop_operating_notices (shop_id,notice_type,notice_date,end_date,end_time)
                        select id,'planned_close','2099-10-19',null,'16:00' from public.ramen_shops where name='서울매장';
                    assert exists(select 1 from public.shop_operating_notices where notice_type='early_close' and notice_category='planned_close'), '구버전 투영과 canonical';
                    begin
                        insert into operating_notice_private.shop_operating_notices (notice_type,notice_date) values('planned_close','2099-10-18');
                        raise exception '시각없는 운영 변동이 저장됨';
                    exception when check_violation then null; end;
                    begin
                        insert into operating_notice_private.shop_operating_notices (notice_type,notice_date) values('early_close','2099-10-18');
                        raise exception '시각없는 조기 마감이 저장됨';
                    exception when check_violation then null; end;
                    assert not exists(select 1 from information_schema.role_routine_grants where routine_name='fetch_operating_notice_feed' and grantee='PUBLIC'), 'PUBLIC 실행 권한 회수';
                    assert (select 'security_invoker=true'=any(reloptions) from pg_class where oid='public.shop_operating_notices'::regclass), 'invoker 뷰 보존';
                end $$;
                set role anon;
                do $$ declare feed jsonb; begin
                    feed := public.fetch_operating_notice_feed('2099-10-18');
                    assert feed->>'reference_date'='2099-10-18', '기준일';
                    assert jsonb_array_length(feed->'items')=4, '가시 매장의 오늘과 미래 공지';
                    assert not (feed::text like '%비공개OCR%'), '내부 OCR 제외';
                    assert exists(select 1 from jsonb_array_elements(feed->'items') item where item->'shop'->>'name'='알수없는매장'), '미상 주소 보존';
                    assert jsonb_array_length(public.fetch_operating_notice_feed('2099-10-19')->'items')=1, '종료일과 미래 공지';
                end $$;
                reset role;
                set role authenticated;
                do $$ begin
                    assert jsonb_array_length(public.fetch_operating_notice_feed('2099-10-18')->'items')=4, '인증 역할 공개 경계';
                end $$;
                reset role;
            """)
            if args.without_regions:
                for role in ("anon", "authenticated"):
                    query(f"""
                        set role {role};
                        do $$ begin
                            assert not exists (
                                select 1 from jsonb_array_elements(public.fetch_operating_notice_feed('2099-10-18')->'items') item
                                where item ? 'area' or item ? 'sigungu'
                            ), '지역 필드가 없는 전국 목록';
                            assert public.fetch_operating_notice_feed(null)->'items'='[]'::jsonb, '기준일이 없으면 빈 목록';
                        end $$;
                        reset role;
                    """)
            else:
                query("""
                    set role anon;
                    do $$ declare feed jsonb; begin
                        feed := public.fetch_operating_notice_feed('2099-10-18');
                        assert exists(select 1 from jsonb_array_elements(feed->'items') item where item->>'area'='SEOUL' and item->>'sigungu'='마포구'), '지역 별칭';
                        assert exists(select 1 from jsonb_array_elements(feed->'items') item where item->>'area'='SEJONG' and item->>'sigungu' is null), '세종 시군구 없음';
                    end $$;
                    reset role;
                """)
            if args.normalize_descriptions:
                query("""
                    insert into operating_notice_private.shop_operating_notices (shop_id,notice_type,notice_date,end_date)
                        select id,'full_close','2099-10-18','2099-10-18' from public.ramen_shops where name='서울매장';
                    do $$ begin
                        assert exists (
                            select 1 from operating_notice_private.shop_operating_notices
                            where notice_type='full_close' and description is null
                        ), '설명이 없는 원본 공지는 보존한다';
                    end $$;
                """)
                for role in ("anon", "authenticated"):
                    query(f"""
                        set role {role};
                        do $$ declare feed jsonb; begin
                            assert exists (
                                select 1 from public.shop_operating_notices
                                where notice_category='full_close' and description=''
                            ), '직접 조회에서도 null 설명을 빈 문자열로 반환한다';
                            assert exists (
                                select 1 from public.shop_operating_notices
                                where notice_category='early_close' and description='공개원문'
                            ), '기존 설명은 그대로 유지한다';
                            feed := public.fetch_operating_notice_feed('2099-10-18');
                            assert jsonb_array_length(feed->'items')=5, '설명이 없는 공지도 목록에서 유지한다';
                            assert not exists (
                                select 1 from jsonb_array_elements(feed->'items') item
                                where jsonb_typeof(item->'notice'->'description') is distinct from 'string'
                            ), '공개 목록의 모든 설명은 문자열이다';
                            assert exists (
                                select 1 from jsonb_array_elements(feed->'items') item
                                where item->'notice'->>'notice_category'='planned_close'
                                  and item->'notice'->>'description'=''
                            ), '운영 변동도 null 설명을 빈 문자열로 반환한다';
                        end $$;
                        reset role;
                    """)
                print("PASS: null descriptions normalized for anon/authenticated direct reads and feed; source text preserved")
            print("PASS: three types, legacy preservation, canonical projection, date/visibility, region contract and role permissions")
        finally:
            subprocess.run(["pg_ctl", "-D", str(database), "-m", "immediate", "-w", "stop"], check=True, capture_output=True)


if __name__ == "__main__":
    main()
