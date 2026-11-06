#!/usr/bin/env python3
"""격리된 로컬 PostgreSQL에서 지도 검색의 관련도, 거리, 공개 범위와 오매칭을 검증한다."""
import argparse
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--migration', type=Path, required=True)
    args = parser.parse_args()
    for command in ('initdb', 'pg_ctl', 'psql'):
        if not shutil.which(command):
            raise SystemExit(f'Required local command: {command}')
    with tempfile.TemporaryDirectory(prefix='ramap-map-search-') as directory:
        folder = Path(directory)
        database = folder / 'db'
        subprocess.run(['initdb', '-D', str(database), '--auth=trust', '--no-locale', '--encoding=UTF8'], check=True, capture_output=True)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        subprocess.run(['pg_ctl', '-D', str(database), '-l', str(folder / 'server.log'), '-o', f'-F -p {port} -h 127.0.0.1 -k {directory}', '-w', 'start'], check=True, capture_output=True)

        def query(sql):
            result = subprocess.run(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-p', str(port), '-d', 'postgres'], input=sql, text=True, capture_output=True)
            if result.returncode:
                raise AssertionError(result.stderr)

        try:
            query('''
                create role anon;
                create role authenticated;
                create table public.ramen_shops (
                    id uuid primary key default gen_random_uuid(), name text not null, address text not null,
                    lat numeric not null default 37, lng numeric not null default 127, is_visible boolean default true,
                    kakao_place_url text, naver_place_url text, business_hours_notice text, business_hours_notice_type text,
                    business_hours_weekly jsonb, business_hours_break_times jsonb, business_hours_last_orders jsonb,
                    instagram_url text, instagram_profile_image_path text, menu_category_ids text[],
                    created_at timestamptz default now(), updated_at timestamptz default now(), internal_note text
                );
                alter table public.ramen_shops enable row level security;
                create policy visible_shops on public.ramen_shops for select to anon,authenticated using (is_visible);
                grant select on public.ramen_shops to anon,authenticated;
                insert into public.ramen_shops(name,address,lat) values
                    ('세종','서울 종로구 테스트로 1',35),
                    ('세종라멘','서울 도봉구 테스트로 2',36),
                    ('서울세종라멘','서울 도봉구 테스트로 3',37.001),
                    ('지역매장','세종특별자치시 한누리대로 1',36.5),
                    ('도로매장','서울 종로구 세종대로23길 21',37.00001),
                    ('멘야 타마시','서울 중구 테스트로 1',37),
                    ('멘야 맛있는 타마시','서울 중구 테스트로 2',37),
                    ('호시노라멘','경기 화성시 만세구 남양읍 시청로202번길 8-40',37.19651162),
                    ('모란라멘','경기 성남시 중원구 테스트로 1',37.42),
                    ('라%_멘','서울 중구 테스트로 1',37),
                    ('라아아멘','서울 중구 테스트로 2',37),
                    ('RAMEN','서울 중구 테스트로 1',37),
                    ('희옥','서울 마포구 잔다리로 71',37),
                    ('멘야 비토리','경기 성남시 중원구 광명로 170',37),
                    ('구','강원특별자치도 속초시 청초호반로 310',37),
                    ('눚','충남 천안시 원두정3길 27',37),
                    ('덴까이','충남 아산시 한누리대로 211',37),
                    ('라멘 더블플러스','경기 과천시 별양상가2로 20',37),
                    ('가솔린라멘 홍대점','서울 마포구 와우산로 1',37),
                    ('아주아주긴매장명으로십오자를넘기는라멘집','서울 중구 테스트로 1',37);
                insert into public.ramen_shops(name,address,business_hours_notice,naver_place_url,internal_note)
                    values ('메모매장','서울 중구 테스트로 1','세종','https://example.com/세종','공개 금지');
                insert into public.ramen_shops(name,address,is_visible) values ('세종숨김','세종 한누리대로 1',false);
                insert into public.ramen_shops(name,address,lat)
                    select '거리라멘 ' || lpad(i::text,2,'0'),'서울 중구 테스트로 1',37+i::numeric/1000
                    from generate_series(60,1,-1) i;
            ''')
            query(args.migration.read_text())
            query('''
                do $$ declare names text[]; begin
                    select array_agg(shop->>'name' order by ord) into names
                    from public.search_map_ramen_shops('세종',37,127) with ordinality r(shop,ord);
                    assert names = array['세종','세종라멘','서울세종라멘','지역매장','도로매장'], '매장명 세 단계와 행정구역·도로명 우선순위';
                    select array_agg(shop->>'name') into names from public.search_map_ramen_shops('멘야타마시') shop;
                    assert names = array['멘야 타마시'], '공백만 무시하고 사이의 다른 글자는 허용하지 않음';
                    select array_agg(shop->>'name') into names from public.search_map_ramen_shops('멘야 타마시') shop;
                    assert names = array['멘야 타마시'], '공백이 있어도 이름 조각 사이 임의 내용을 허용하지 않음';
                    assert (select array_agg(shop->>'id' order by ord) from public.search_map_ramen_shops('홍대 가솔린') with ordinality r(shop,ord))
                         = (select array_agg(shop->>'id' order by ord) from public.search_map_ramen_shops('홍대가솔린') with ordinality r(shop,ord)), '역순 지점 검색도 공백 정규화가 같음';
                    assert not exists(select 1 from public.search_map_ramen_shops('성남 시청')), '화성시 남양읍 시청로 오매칭 제거';
                    select array_agg(shop->>'name') into names from public.search_map_ramen_shops('성남') shop;
                    assert cardinality(names)=2 and names @> array['모란라멘','멘야 비토리'], '행정구역의 시 접미사 생략';
                    select array_agg(shop->>'name') into names from public.search_map_ramen_shops('세종시') shop;
                    assert names = array['지역매장'], '세종시와 세종특별자치시 별칭 일치';
                    select array_agg(shop->>'name') into names from public.search_map_ramen_shops('라%_멘') shop;
                    assert names = array['라%_멘'], '와일드카드를 실제 문자로 비교';
                    assert (select shop->>'name' from public.search_map_ramen_shops('ＲＡＭＥＮ') shop) = 'RAMEN', '유니코드 정규화';
                    select array_agg(shop->>'name' order by ord) into names
                    from public.search_map_ramen_shops('거리라멘',37,127,50) with ordinality r(shop,ord);
                    assert cardinality(names)=50 and names[1]='거리라멘 01' and names[50]='거리라멘 50', '전체 후보 거리순 정렬 후 50개 제한';
                    assert not exists(select 1 from public.search_map_ramen_shops('라')), '한 글자 부분일치로 무관한 매장을 확장하지 않음';
                    assert (select shop->>'name' from public.search_map_ramen_shops('구') shop)='구', '한 글자 상호 정확 일치';
                    assert (select shop->>'name' from public.search_map_ramen_shops('속초 구') shop)='구', '한 글자 상호와 지역 복합 검색';
                    assert (select shop->>'name' from public.search_map_ramen_shops('구속초') shop)='구', '한 글자 상호 지역 순서와 공백 정규화';
                    assert (select shop->>'name' from public.search_map_ramen_shops('한누리대로 덴까이') shop)='덴까이', '도로명과 상호 복합 검색';
                    assert (select shop->>'name' from public.search_map_ramen_shops('더블플러스 라멘더블플러스') shop)='라멘 더블플러스', '전체 상호에 이미 포함된 검색 한정어';
                    assert (select shop->>'name' from public.search_map_ramen_shops('눚') shop)='눚', '한 글자 상호 검색';
                    assert (select shop->>'name' from public.search_map_ramen_shops('아주아주긴매장명으로십오자를넘기는라멘집') shop)='아주아주긴매장명으로십오자를넘기는라멘집', '긴 상호 전체 입력';
                    assert (select shop->>'name' from public.search_map_ramen_shops('성남 비토리') shop)='멘야 비토리', '지역과 매장명 복합 검색';
                    assert (select shop->>'name' from public.search_map_ramen_shops('비토리 성남') shop)='멘야 비토리', '지역 순서 변경';
                    assert (select shop->>'name' from public.search_map_ramen_shops('성남비토리') shop)='멘야 비토리', '지역과 상호를 붙여 입력';
                    assert (select shop->>'name' from public.search_map_ramen_shops('마포 희옥') shop)='희옥', '시군구 접미사 생략';
                    assert (select shop->>'name' from public.search_map_ramen_shops('희옥 서울시') shop)='희옥', '광역지역 별칭 복합 검색';
                    assert (select shop->>'name' from public.search_map_ramen_shops('비토리 멘야') shop)='멘야 비토리', '상호 단어 순서 변경';
                    assert not exists(select 1 from public.search_map_ramen_shops('수원 비토리')), '다른 지역 매장 제외';
                    assert not exists(select 1 from public.search_map_ramen_shops('마X포 희옥')), '복합 검색에서도 글자 사이 임의 내용 불허';
                    assert not exists(select 1 from public.search_map_ramen_shops(repeat('가',101))), '긴 입력 거절';
                    assert not exists(select 1 from public.search_map_ramen_shops('세종') shop where shop ? 'internal_note'), '내부 필드 비공개';
                    assert (select array_agg(shop->>'id' order by ord) from public.search_map_ramen_shops('세종') with ordinality r(shop,ord))
                         = (select array_agg(shop->>'id' order by ord) from public.search_map_ramen_shops('세종') with ordinality r(shop,ord)), '좌표 없는 검색 순서 고정';
                    begin
                        perform public.search_map_ramen_shops('세종',37,null);
                        raise exception '부분 좌표 허용';
                    exception when invalid_parameter_value then null; end;
                    begin
                        perform public.search_map_ramen_shops('세종','NaN'::float8,127);
                        raise exception 'NaN 좌표 허용';
                    exception when invalid_parameter_value then null; end;
                end $$;
                set role anon;
                do $$ begin
                    assert not exists(select 1 from public.search_map_ramen_shops('세종') shop where shop->>'name'='세종숨김'), '익명 공개 범위';
                end $$;
                reset role;
                drop policy visible_shops on public.ramen_shops;
                create policy no_shops on public.ramen_shops for select to anon using (false);
                set role anon;
                do $$ begin
                    assert not exists(select 1 from public.search_map_ramen_shops('세종')), '호출자 RLS 보존';
                end $$;
            ''')
            print('지도 검색 SQL: 관련도·연속일치·지역·거리·50개·입력·RLS 검증 통과')
        finally:
            subprocess.run(['pg_ctl', '-D', str(database), '-m', 'immediate', '-w', 'stop'], check=True, capture_output=True)


if __name__ == '__main__':
    main()
