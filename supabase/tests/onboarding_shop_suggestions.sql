-- Run with psql -X -v ON_ERROR_STOP=1 on an empty local PostgreSQL database.
begin;

create role anon;
create role authenticated;
create role other_reader;
create table public.ramen_shops (
    id uuid primary key,
    name text not null default '테스트 라멘',
    address text not null default '서울 마포구',
    lat numeric not null default 37,
    lng numeric not null default 127,
    is_visible boolean not null,
    restricted boolean not null default false,
    kakao_place_url text,
    naver_place_url text,
    business_hours_weekly jsonb,
    business_hours_break_times jsonb,
    business_hours_last_orders jsonb,
    business_hours_notice text,
    business_hours_notice_type text,
    instagram_url text,
    instagram_profile_image_path text,
    menu_category_ids text[],
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
alter table public.ramen_shops enable row level security;
create policy readable_shops on public.ramen_shops
    for select to anon, authenticated using (not restricted);
grant select on public.ramen_shops to anon, authenticated;

insert into public.ramen_shops (id, is_visible, restricted)
select md5(number::text)::uuid, number <> 56, number = 57
from generate_series(1, 57) number;

\ir ../migrations/20261111063945_randomize_onboarding_shop_suggestions.sql

do $$
begin
    assert not has_function_privilege('other_reader', 'public.fetch_onboarding_shop_suggestions(text,integer)', 'execute'),
        '공개 API 역할에만 실행을 허용한다';
    assert has_function_privilege('authenticated', 'public.fetch_onboarding_shop_suggestions(text,integer)', 'execute');
end;
$$;

set local role anon;
do $$
declare
    first_page jsonb := public.fetch_onboarding_shop_suggestions();
    cursor_token text := first_page ->> 'next_cursor';
    seed text := split_part(cursor_token, ':', 1);
    second_page jsonb := public.fetch_onboarding_shop_suggestions(cursor_token);
    last_page jsonb := public.fetch_onboarding_shop_suggestions(second_page ->> 'next_cursor');
    all_shops jsonb := (first_page -> 'shops') || (second_page -> 'shops') || (last_page -> 'shops');
begin
    assert jsonb_array_length(first_page -> 'shops') = 20;
    assert jsonb_array_length(second_page -> 'shops') = 20;
    assert jsonb_array_length(last_page -> 'shops') = 15;
    assert (first_page -> 'shops' -> 0 ->> 'name') = '테스트 라멘';
    assert not (first_page -> 'shops' -> 0) ? 'restricted', '내부 필드를 응답에 포함하지 않는다';
    assert last_page ->> 'next_cursor' is null, '마지막 페이지에서는 커서를 반환하지 않는다';
    assert second_page = public.fetch_onboarding_shop_suggestions(cursor_token), '같은 커서로 재시도하면 같은 페이지를 받는다';
    assert (
        select array_agg((shop ->> 'id')::uuid order by ordinality)
        from jsonb_array_elements(all_shops) with ordinality as rows(shop, ordinality)
    ) = (
        select array_agg(id order by md5(seed || id::text)::uuid, id)
        from public.ramen_shops where is_visible
    ), '전체 페이지가 같은 무작위 순서를 따르며 중복·누락·숨김 매장이 없다';
    assert (
        select count(distinct public.fetch_onboarding_shop_suggestions() -> 'shops') > 1
        from generate_series(1, 6)
    ), '첫 페이지를 새로 조회하면 다른 무작위 순서를 받을 수 있다';
    assert jsonb_array_length(public.fetch_onboarding_shop_suggestions(p_limit => 500) -> 'shops') = 50;
end;
$$;

reset role;
delete from public.ramen_shops;
set local role anon;
do $$
begin
    assert public.fetch_onboarding_shop_suggestions() = '{"shops": [], "next_cursor": null}'::jsonb;
end;
$$;

rollback;
