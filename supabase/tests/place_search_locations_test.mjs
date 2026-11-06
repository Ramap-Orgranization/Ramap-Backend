import test from 'node:test';
import assert from 'node:assert/strict';
import { parseInput, searchPlaces } from '../functions/place-search/place_search.ts';

const center = { lat: 37.42, lng: 127.127 };
const input = (query) => ({ query, center, mode: 'locations' });
const item = (title, category, lat = 37.42) => ({ title, category, roadAddress: '경기 성남시 중원구 성남대로 997', mapx: '1271270000', mapy: String(Math.round(lat * 10000000)) });
const noShopLookup = async () => { throw new Error('장소 검색에서 전체 매장 조회 금지'); };

test('성남 시청은 공백 차이 없는 시청 후보를 반환하고 임의 역 검색을 추가하지 않는다', async () => {
  const requests = [];
  const results = await searchPlaces(input('성남 시청'), async (query) => {
    requests.push(query);
    return { items: [item('성남시청 주변 식당', '음식점>일식'), item('<b>성남시청</b>', '공공,사회기관>시청')] };
  }, async () => { throw new Error('일반 장소 지오코딩 금지'); }, noShopLookup);
  assert.deepEqual(requests, ['성남시청']);
  assert.equal(results.length, 1);
  assert.equal(results[0].name, '성남시청');
  assert.equal(results[0].kind, 'map_location');
  assert.equal(results[0].shop_id, undefined);
});

test('가까운 부속 장소보다 이름이 정확한 목적지를 먼저 반환한다', async () => {
  const results = await searchPlaces(input('성남 시청'), async () => ({ items: [
    item('성남시청 주차장', '교통,운수>주차장', 37.42001),
    item('성남시청', '공공,사회기관>시청', 37.43),
  ] }), async () => ({}), noShopLookup);
  assert.deepEqual(results.map((place) => place.name), ['성남시청', '성남시청 주차장']);
});

test('행정구역은 지오코딩하고 지역 표기를 유지한다', async () => {
  const results = await searchPlaces(input('세종'), async () => { throw new Error('추가 지역검색 금지'); }, async (query) => {
    assert.equal(query, '세종');
    return { status: 'OK', addresses: [{ roadAddress: '세종특별자치시', x: '127.289', y: '36.48' }] };
  }, noShopLookup);
  assert.equal(results[0].name, '세종');
  assert.equal(results[0].kind, 'map_location');
});

test('장소 조회 실패와 정상 빈 결과를 구분한다', async () => {
  await assert.rejects(searchPlaces(input('세종'), async () => ({}), async () => { throw new Error('provider failure'); }, noShopLookup), /provider failure/);
  assert.deepEqual(await searchPlaces(input('세종'), async () => ({}), async () => ({ status: 'OK', addresses: [] }), noShopLookup), []);
});

test('관련 없는 이름과 미등록 음식점은 지도 목적지 후보로 넣지 않는다', async () => {
  const results = await searchPlaces(input('성남 시청'), async () => ({ items: [
    item('다른시청', '공공,사회기관>시청'), item('성남시청라멘', '음식점>일식>일본식라면'),
  ] }), async () => ({}), noShopLookup);
  assert.deepEqual(results, []);
});

test('희옥정육점 같은 일반 판매점은 지도 목적지 후보로 넣지 않는다', async () => {
  const results = await searchPlaces(input('희옥'), async () => ({ items: [
    item('희옥정육점', '쇼핑,유통>식료품>정육점'),
    item('희옥신발', '쇼핑,유통>신발'),
    item('희옥', '음식점>일식>일본식라면'),
  ] }), async () => ({}), noShopLookup);
  assert.deepEqual(results, []);
});

test('백화점과 시장은 일반 판매점과 구분해 장소 후보로 유지한다', async () => {
  const results = await searchPlaces(input('중앙시장'), async () => ({ items: [
    item('중앙백화점', '쇼핑,유통>백화점'),
    item('중앙시장', '쇼핑,유통>종합소매>시장'),
  ] }), async () => ({}), noShopLookup);
  assert.deepEqual(results.map((place) => place.name), ['중앙시장']);
});

test('비토리처럼 상위 지역 없이 입력한 동리 이름은 모호한 지역 후보로 표시한다', async () => {
  for (const query of ['비토리', '비 토 리', '야탑동']) {
    const regionName = query.replaceAll(' ', '');
    const results = await searchPlaces(input(query), async () => ({}), async () => ({
      status: 'OK', addresses: [{ jibunAddress: `경기도 성남시 ${regionName}`, x: '127.145', y: '37.441' }],
    }), noShopLookup);
    assert.equal(results[0].is_ambiguous_region, true);
  }
});

test('광역 지역과 상위 지역을 함께 입력한 동리는 모호한 지역으로 분류하지 않는다', async () => {
  for (const query of ['세종', '사천시 서포면 비토리']) {
    const results = await searchPlaces(input(query), async () => ({}), async () => ({
      status: 'OK', addresses: [{ jibunAddress: query === '세종' ? '세종특별자치시' : '경상남도 사천시 서포면 비토리', x: '127.145', y: '37.441' }],
    }), noShopLookup);
    assert.notEqual(results[0].is_ambiguous_region, true);
  }
});

test('지도 장소 모드는 명시적으로 선택하고 잘못된 모드는 거절한다', () => {
  assert.equal(parseInput(input('성남 시청')).mode, 'locations');
  assert.equal(parseInput({ query: '세종', center }).mode, undefined);
  assert.equal(parseInput({ query: '세종', center, mode: 'unknown' }), null);
});


test('상호 조각으로 의원과 학원과 기념비와 빌라를 확장하지 않는다', async () => {
  for (const [query, name, category] of [
    ['리네', '리네성형외과의원', '병원,의원>성형외과'],
    ['면밀', '면밀', '생활,편의>일반서비스'],
    ['면밀', '면밀', '문화,예술>공방'],
    ['면작', '문익점면작기념비', '여행,명소>기념비'],
    ['일락', '일락하우스빌라', '부동산>주거>빌라'],
    ['겐키', '겐키일본어센터', '교육,학문>학원'],
    ['소요', '소요산', '여행,명소>산'],
    ['은월', '은월공원', '여행,명소>공원'],
    ['펀치', '펀치토킹', '문화,예술'],
  ]) {
    const results = await searchPlaces(input(query), async () => ({ items: [item(name, category)] }), async () => ({}), noShopLookup);
    assert.deepEqual(results, [], query);
  }
});

test('지오코딩 결과에 없는 검색 글자를 버리고 다른 지역으로 이동하지 않는다', async () => {
  const results = await searchPlaces(input('해X도'), async () => ({}), async () => ({
    status: 'OK', addresses: [{ jibunAddress: '경상북도 포항시 남구 해도동', x: '129.371447', y: '36.023286' }],
  }), noShopLookup);
  assert.deepEqual(results, []);
});

test('시도 별칭과 공백을 무시한 행정구역은 실제 주소와 대조한다', async () => {
  for (const query of ['경기 성남시', '경기도성남시', '성남시', '경기성남시']) {
    const results = await searchPlaces(input(query), async () => ({}), async () => ({
      status: 'OK', addresses: [{ jibunAddress: '경기도 성남시', x: '127.1', y: '37.4' }],
    }), noShopLookup);
    assert.equal(results.length, 1, query);
  }
});

test('읍면의 모호한 지역도 매장명보다 우선하지 않도록 표시한다', async () => {
  const results = await searchPlaces(input('판교면'), async () => ({}), async () => ({
    status: 'OK', addresses: [{ jibunAddress: '충청남도 서천군 판교면', x: '126.6', y: '36.1' }],
  }), noShopLookup);
  assert.equal(results[0].is_ambiguous_region, true);
});

test('대학 약칭은 본교와 캠퍼스를 찾고 대학원이나 부속 시설을 섞지 않는다', async () => {
  for (const university of ['아주', '부산', '경희']) {
    const results = await searchPlaces(input(`${university}대`), async (query) => {
      assert.equal(query, `${university}대학교`);
      return { items: [
        item(`${university}대학교 교육대학원`, '교육,학문>대학원', 37.42001),
        item(`${university}대학교 서울캠퍼스`, '교육,학문>대학교', 37.5),
        item(`${university}대학교`, '교육,학문>대학교', 37.7),
      ] };
    }, async () => ({}), noShopLookup);
    assert.deepEqual(results.map((place) => place.name), [`${university}대학교`, `${university}대학교 서울캠퍼스`]);
  }
});

test('서면은 무관한 의원 대신 서면역으로 탐색한다', async () => {
  const results = await searchPlaces(input('서면'), async (query) => {
    assert.equal(query, '서면역');
    return { items: [item('서면역 1호선', '교통,운수>지하철,전철')] };
  }, async () => ({}), noShopLookup);
  assert.equal(results.length, 1);
});

test('한 글자 검색은 외부 장소로 확장하지 않고 긴 검색 입력은 허용한다', async () => {
  assert.equal(parseInput(input('가'.repeat(100))).query.length, 100);
  assert.equal(parseInput(input('가'.repeat(101))), null);
  const results = await searchPlaces(input('구'), async () => { throw new Error('한 글자 외부 조회 금지'); }, async () => ({}), noShopLookup);
  assert.deepEqual(results, []);
});

test('지오코딩은 가까운 오매칭을 제거한 뒤 올바른 지역 후보를 선택한다', async () => {
  const results = await searchPlaces(input('서울 마포구'), async () => ({}), async () => ({
    status: 'OK', addresses: [
      { jibunAddress: '경기도 성남시', x: '127.127', y: '37.42' },
      { jibunAddress: '서울특별시 마포구', x: '126.9', y: '37.5' },
    ],
  }), noShopLookup);
  assert.equal(results.length, 1);
  assert.equal(results[0].address, '서울특별시 마포구');
});
