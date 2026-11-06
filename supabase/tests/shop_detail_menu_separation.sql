-- Run only in an isolated staging database. All fixture writes are rolled back.
begin;
set local statement_timeout = '30s';
create temporary table menu_split_fixture_ids(label text primary key, id uuid default gen_random_uuid());
insert into menu_split_fixture_ids(label) values
    ('shop'), ('hidden_shop'), ('empty_shop'), ('missing_shop'),
    ('permanent_section'), ('special_section'), ('hidden_section'), ('empty_section'), ('hidden_shop_section'),
    ('permanent_menu'), ('special_menu'), ('hidden_menu'), ('hidden_section_menu'), ('hidden_shop_menu'), ('expired_menu'),
    ('active_event'), ('expired_event');
grant select on menu_split_fixture_ids to anon, authenticated;

insert into public.ramen_shops(id, name, address, lat, lng, is_visible, waiting_provider, waiting_provider_url)
select id, '메뉴 분리 회귀 픽스처', '테스트 주소', 37.5, 127.0, label <> 'hidden_shop',
       case when label = 'shop' then 'catchtable' end,
       case when label = 'shop' then 'https://example.com/waiting' end
from menu_split_fixture_ids where label in ('shop', 'hidden_shop', 'empty_shop');

insert into public.shop_menu_sections(id, shop_id, title, display_order, is_visible)
select section.id,
       (select id from menu_split_fixture_ids where label = case when section.label = 'hidden_shop_section' then 'hidden_shop' else 'shop' end),
       case when section.label = 'permanent_section' then ' 상시메뉴 ' else section.label end,
       case when section.label = 'permanent_section' then 0 else 9 end,
       section.label <> 'hidden_section'
from menu_split_fixture_ids section where section.label like '%section';

insert into public.shop_events(id, shop_id, title, description, start_date, end_date, event_type, source_url)
select event.id, (select id from menu_split_fixture_ids where label='shop'), event.label, '테스트 설명',
       (current_timestamp at time zone 'Asia/Seoul')::date - 2,
       (current_timestamp at time zone 'Asia/Seoul')::date + case when event.label='active_event' then 1 else -1 end,
       'limited_menu', 'https://example.com/event'
from menu_split_fixture_ids event where label in ('active_event', 'expired_event');

insert into public.shop_menu_items(id, section_id, name, display_order, price_krw, is_visible, event_id)
select item.id,
       (select id from menu_split_fixture_ids where label = case
            when item.label = 'hidden_section_menu' then 'hidden_section'
            when item.label = 'hidden_shop_menu' then 'hidden_shop_section'
            when item.label = 'permanent_menu' then 'permanent_section'
            else 'special_section' end),
       item.label, 0, 10000, item.label <> 'hidden_menu',
       case when item.label = 'special_menu' then (select id from menu_split_fixture_ids where label='active_event')
            when item.label = 'expired_menu' then (select id from menu_split_fixture_ids where label='expired_event') end
from menu_split_fixture_ids item where item.label like '%menu';

insert into public.shop_event_participants(event_id, shop_id)
select event.id, shop.id from menu_split_fixture_ids event cross join menu_split_fixture_ids shop
where event.label='active_event' and shop.label='shop';

-- Compare both APIs under real public reader roles; RLS must stay in effect.
do $test$
declare
    actor text;
    shop_id uuid := (select id from menu_split_fixture_ids where label='shop');
    empty_id uuid := (select id from menu_split_fixture_ids where label='empty_shop');
    hidden_id uuid := (select id from menu_split_fixture_ids where label='hidden_shop');
    missing_id uuid := (select id from menu_split_fixture_ids where label='missing_shop');
    old_detail record;
    new_detail record;
    menu record;
begin
    assert not (select prosecdef from pg_proc where oid='public.fetch_shop_detail_v3(uuid)'::regprocedure), '상세 API는 호출자 권한을 유지한다';
    assert not (select prosecdef from pg_proc where oid='public.fetch_shop_menu(uuid)'::regprocedure), '메뉴 API는 호출자 권한을 유지한다';
    assert position('shop_menu' in pg_get_functiondef('public.fetch_shop_detail_v3(uuid)'::regprocedure)) = 0, '상세 API는 메뉴를 조회하지 않는다';
    for actor in select unnest(array['anon','authenticated']) loop
        perform set_config('role', actor, true);
        select * into strict old_detail from public.fetch_shop_detail_v2(shop_id);
        select * into strict new_detail from public.fetch_shop_detail_v3(shop_id);
        select * into strict menu from public.fetch_shop_menu(shop_id);
        assert new_detail.shop = old_detail.shop - 'phone' - 'kakao_place_id', '매장 기본 정보와 웨이팅 컬럼을 유지한다';
        assert new_detail.like_count = old_detail.like_count, '좋아요 수를 유지한다';
        assert new_detail.events = old_detail.events, '활성 이벤트를 유지한다';
        assert jsonb_array_length(new_detail.events) = 1, '종료 이벤트를 제외한다';
        assert new_detail.event_participants = old_detail.event_participants, '활성 이벤트 참여자를 유지한다';
        assert jsonb_array_length(new_detail.event_participants) = 1, '활성 이벤트 참여자 픽스처를 조회한다';
        assert new_detail.operating_notice is not distinct from old_detail.operating_notice, '운영 공지를 유지한다';
        assert new_detail.shop->>'waiting_provider' = old_detail.waiting_system->>'provider', '웨이팅 제공자를 유지한다';
        assert new_detail.shop->>'waiting_provider_url' = old_detail.waiting_system->>'provider_url', '웨이팅 URL을 유지한다';
        assert to_jsonb(new_detail) - array['shop','like_count','events','event_participants','operating_notice'] = '{}'::jsonb, '상세 응답에는 메뉴나 리뷰 필드가 없다';
        assert menu.menu_sections = old_detail.menu_sections, '메뉴 섹션 순서와 공개 범위를 유지한다';
        assert menu.menu_items = old_detail.menu_items, '메뉴 항목의 순서와 공개 범위를 유지한다';
        assert menu.menu_updated_at is not distinct from old_detail.menu_updated_at, '메뉴 갱신 시각을 유지한다';
        assert jsonb_array_length(menu.menu_sections) = 3, '비공개 섹션을 제외하고 빈 공개 섹션은 DTO에서 처리한다';
        assert jsonb_array_length(menu.menu_items) = 2, '비공개 항목과 섹션 및 종료 이벤트 메뉴를 제외한다';
        assert menu.menu_sections->-1->>'title' = ' 상시메뉴 ', '상시 메뉴는 마지막에 정렬한다';
        select * into strict menu from public.fetch_shop_menu(empty_id);
        assert menu.menu_sections = '[]'::jsonb and menu.menu_items = '[]'::jsonb and menu.menu_updated_at is null, '메뉴 없는 매장은 성공한 빈 메뉴다';
        assert not exists(select 1 from public.fetch_shop_detail_v3(hidden_id)), '숨김 매장 상세는 공개하지 않는다';
        assert not exists(select 1 from public.fetch_shop_menu(hidden_id)), '숨김 매장 메뉴는 공개하지 않는다';
        assert not exists(select 1 from public.fetch_shop_detail_v3(missing_id)), '없는 매장 상세는 조회되지 않는다';
        assert not exists(select 1 from public.fetch_shop_menu(missing_id)), '없는 매장 메뉴는 빈 메뉴 성공이 아니다';
        perform set_config('role', 'none', true);
    end loop;
end;
$test$;
rollback;
