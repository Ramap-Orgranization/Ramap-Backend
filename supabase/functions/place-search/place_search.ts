import { SearchBudgetError } from "./search_budget.ts";

export const MAX_RESULTS = 5;

export type SearchCenter = {
  lat: number;
  lng: number;
};

export type PlaceSearchInput = {
  query: string;
  center: SearchCenter;
  mode?: "locations";
};

export type NaverSearch = (query: string) => Promise<unknown>;
export type NaverGeocode = (
  query: string,
  center: SearchCenter,
) => Promise<unknown>;
export type ShopSearch = () => Promise<RegisteredShop[]>;

export type RegisteredShop = {
  id: string;
  naverPlaceId: string | null;
  name: string;
  address: string;
  lat: number;
  lng: number;
};

export type PlaceSearchResult = {
  name: string;
  address: string;
  lat: number;
  lng: number;
  kind: "map_location" | "registered_shop";
  shop_id?: string;
  zoom?: number;
  is_ambiguous_region?: boolean;
};

type NaverLocalItem = {
  title?: unknown;
  link?: unknown;
  category?: unknown;
  address?: unknown;
  roadAddress?: unknown;
  mapx?: unknown;
  mapy?: unknown;
};

type NaverLocalResponse = {
  items?: unknown;
};

type NaverGeocodeAddress = {
  roadAddress?: unknown;
  jibunAddress?: unknown;
  x?: unknown;
  y?: unknown;
};

type NaverGeocodeResponse = {
  status?: unknown;
  addresses?: unknown;
};

type ParsedNaverItem = {
  name: string;
  address: string;
  lat: number;
  lng: number;
  category: string;
  naverPlaceId: string | null;
};

const STATION_DEDUPLICATION_DISTANCE_METERS = 300;
const SHOP_MATCH_DISTANCE_METERS = 100;
const RAIL_STATION_CATEGORY_MARKERS = [
  "지하철,전철",
  "지하철역",
  "전철역",
  "기차역",
  "철도역",
  "도시철도",
];
const ADMINISTRATIVE_REGION_SUFFIX_MIN_LENGTH = new Map([
  ["특별자치시", 6],
  ["특별자치도", 6],
  ["특별시", 4],
  ["광역시", 4],
  ["시", 3],
  ["도", 3],
  ["구", 3],
  ["군", 3],
  ["동", 3],
  ["읍", 3],
  ["면", 3],
  ["리", 3],
]);
const TOP_LEVEL_REGION_ALIASES = new Set([
  "서울",
  "부산",
  "대구",
  "인천",
  "광주",
  "대전",
  "울산",
  "세종",
  "경기",
  "강원",
  "충북",
  "충남",
  "전북",
  "전남",
  "경북",
  "경남",
  "제주",
]);

export function parseInput(value: unknown): PlaceSearchInput | null {
  if (!isRecord(value) || typeof value.query !== "string") return null;
  if (!isRecord(value.center)) return null;

  const query = value.query.trim();
  const lat = value.center.lat;
  const lng = value.center.lng;
  if (query.length === 0 || query.length > 100) return null;
  if (value.mode !== undefined && value.mode !== null && value.mode !== "locations") return null;
  if (!isCoordinate(lat, -90, 90) || !isCoordinate(lng, -180, 180)) {
    return null;
  }

  return { query, center: { lat, lng }, ...(value.mode === "locations" ? { mode: "locations" as const } : {}) };
}

export async function searchPlaces(
  input: PlaceSearchInput,
  searchNaver: NaverSearch,
  geocodeNaver: NaverGeocode,
  searchShops: ShopSearch,
): Promise<PlaceSearchResult[]> {
  if (input.mode === "locations") {
    return await searchLocationCandidates(input, searchNaver, geocodeNaver);
  }
  if (isStationQuery(input.query)) {
    return await searchStation(input.query, input.center, searchNaver);
  }
  if (isAdministrativeRegionQuery(input.query) || isAddressQuery(input.query)) {
    return await searchMapLocation(input, geocodeNaver);
  }

  const generalPayload = await searchNaver(input.query);
  const generalItems = parseNaverItems(generalPayload, input.center);
  const stationAliasResults = await searchStationAlias(
    input,
    searchNaver,
  );
  if (stationAliasResults.length > 0) return stationAliasResults;

  const shops = await searchShops();
  return matchRegisteredShops(generalItems, shops).slice(0, MAX_RESULTS);
}

export function matchRegisteredShops(
  items: ParsedNaverItem[],
  shops: RegisteredShop[],
): PlaceSearchResult[] {
  const results: PlaceSearchResult[] = [];
  const matchedShopIds = new Set<string>();
  for (const item of items) {
    const matchedShop = findRegisteredShop(item, shops);
    if (matchedShop === null || matchedShopIds.has(matchedShop.id)) continue;
    matchedShopIds.add(matchedShop.id);
    results.push({
      name: matchedShop.name,
      address: matchedShop.address,
      lat: matchedShop.lat,
      lng: matchedShop.lng,
      kind: "registered_shop",
      shop_id: matchedShop.id,
    });
  }
  return results;
}

export function isAdministrativeRegionQuery(query: string): boolean {
  const normalizedQuery = normalizeSearchText(query);
  if (normalizedQuery.length === 0 || normalizedQuery.endsWith("역")) {
    return false;
  }
  if (TOP_LEVEL_REGION_ALIASES.has(normalizedQuery)) return true;
  return [...ADMINISTRATIVE_REGION_SUFFIX_MIN_LENGTH].some(
    ([suffix, minimumLength]) =>
      normalizedQuery.length >= minimumLength && normalizedQuery.endsWith(suffix),
  );
}

export function isAddressQuery(query: string): boolean {
  const normalizedQuery = query.normalize("NFKC").trim();
  return /(?:로|길|번길)\s*\d/.test(normalizedQuery) ||
    /\d+(?:-\d+)?(?:번지)?$/.test(normalizedQuery);
}

export function stripTitleHtml(title: string): string {
  return title
    .replace(/<[^>]*>/g, "")
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .trim();
}

function parseNaverItems(
  value: unknown,
  center: SearchCenter,
): ParsedNaverItem[] {
  if (!isRecord(value)) return [];
  const items = (value as NaverLocalResponse).items;
  if (!Array.isArray(items)) return [];
  return items
    .map(parseNaverItem)
    .filter((item): item is ParsedNaverItem => item !== null)
    .sort((left, right) =>
      distanceSquared(left, center) - distanceSquared(right, center)
    )
    .slice(0, MAX_RESULTS);
}

function parseNaverItem(value: unknown): ParsedNaverItem | null {
  if (!isRecord(value)) return null;
  const item = value as NaverLocalItem;
  if (
    typeof item.title !== "string" ||
    typeof item.mapx !== "string" ||
    typeof item.mapy !== "string"
  ) {
    return null;
  }

  const lng = Number(item.mapx) / 10_000_000;
  const lat = Number(item.mapy) / 10_000_000;
  if (!isCoordinate(lat, -90, 90) || !isCoordinate(lng, -180, 180)) {
    return null;
  }
  const address = selectAddress(item.roadAddress, item.address);
  const name = stripTitleHtml(item.title);
  if (name.length === 0 || address.length === 0) return null;

  return {
    name,
    address,
    lat,
    lng,
    category: typeof item.category === "string" ? item.category : "",
    naverPlaceId: extractNaverPlaceId(item.link),
  };
}

export function extractNaverPlaceId(value: unknown): string | null {
  if (typeof value !== "string" || value.trim().length === 0) return null;
  try {
    const url = new URL(value);
    const match = url.pathname.match(
      /\/(?:place|restaurant|cafe|hospital|pharmacy)\/(\d{5,})(?:\/|$)/,
    );
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

function findRegisteredShop(
  item: ParsedNaverItem,
  shops: RegisteredShop[],
): RegisteredShop | null {
  if (item.naverPlaceId !== null) {
    const idMatch = shops.find((shop) =>
      shop.naverPlaceId === item.naverPlaceId
    );
    if (idMatch !== undefined) return idMatch;
  }

  const normalizedName = normalizeMatchText(item.name);
  return shops.find((shop) => {
    if (normalizeMatchText(shop.name) !== normalizedName) return false;
    const hasSameAddress = normalizeAddress(shop.address) ===
      normalizeAddress(item.address);
    const isNearby = distanceMeters(shop, item) <= SHOP_MATCH_DISTANCE_METERS;
    return hasSameAddress || isNearby;
  }) ?? null;
}

async function searchStation(
  query: string,
  center: SearchCenter,
  searchNaver: NaverSearch,
): Promise<PlaceSearchResult[]> {
  const payload = await searchNaver(query);
  const normalizedQuery = normalizeSearchText(query);
  const stationItems = parseNaverItems(payload, center)
    .filter((item) =>
      isRailStationCategory(item.category) &&
      normalizeSearchText(item.name).includes(normalizedQuery)
    )
    .sort((left, right) => compareStationRepresentatives(left, right, center));

  return stationItems
    .filter((item, index, allItems) =>
      allItems.slice(0, index).every((previous) =>
        distanceMeters(item, previous) > STATION_DEDUPLICATION_DISTANCE_METERS
      )
    )
    .map(toMapLocation)
    .slice(0, MAX_RESULTS);
}

async function searchStationAlias(
  input: PlaceSearchInput,
  searchNaver: NaverSearch,
): Promise<PlaceSearchResult[]> {
  const normalizedQuery = normalizeSearchText(input.query);
  if (normalizedQuery.length === 0 || normalizedQuery.includes(" ")) return [];
  return await searchStation(`${input.query}역`, input.center, searchNaver);
}

async function searchMapLocation(
  input: PlaceSearchInput,
  geocodeNaver: NaverGeocode,
): Promise<PlaceSearchResult[]> {
  try {
    const payload = await geocodeNaver(input.query, input.center);
    return parseNaverGeocodeResponse(payload, input.center, input.query);
  } catch (error) {
    if (error instanceof SearchBudgetError) throw error;
    return [];
  }
}

function parseNaverGeocodeResponse(
  value: unknown,
  center: SearchCenter,
  query: string,
  validateQuery = false,
): PlaceSearchResult[] {
  if (!isRecord(value)) return [];
  const response = value as NaverGeocodeResponse;
  if (response.status !== "OK" || !Array.isArray(response.addresses)) return [];

  return response.addresses
    .map((address) => parseNaverGeocodeAddress(address, query))
    .filter((result): result is PlaceSearchResult => result !== null)
    .filter((result) => !validateQuery || matchesGeocodedAddress(result.address, query))
    .sort((left, right) =>
      distanceSquared(left, center) - distanceSquared(right, center)
    )
    .slice(0, 1);
}

function parseNaverGeocodeAddress(
  value: unknown,
  query: string,
): PlaceSearchResult | null {
  if (!isRecord(value)) return null;
  const geocodeAddress = value as NaverGeocodeAddress;
  if (
    typeof geocodeAddress.x !== "string" ||
    typeof geocodeAddress.y !== "string"
  ) {
    return null;
  }
  const lng = Number(geocodeAddress.x);
  const lat = Number(geocodeAddress.y);
  if (!isCoordinate(lat, -90, 90) || !isCoordinate(lng, -180, 180)) {
    return null;
  }
  const address = selectAddress(
    geocodeAddress.roadAddress,
    geocodeAddress.jibunAddress,
  );
  if (address.length === 0) return null;
  return {
    name: query.trim(),
    address,
    lat,
    lng,
    kind: "map_location",
  };
}

function selectAddress(primary: unknown, fallback: unknown): string {
  if (typeof primary === "string" && primary.trim().length > 0) {
    return primary.trim();
  }
  return typeof fallback === "string" ? fallback.trim() : "";
}

function toMapLocation(item: ParsedNaverItem): PlaceSearchResult {
  return {
    name: item.name,
    address: item.address,
    lat: item.lat,
    lng: item.lng,
    kind: "map_location",
  };
}

function compareStationRepresentatives(
  left: ParsedNaverItem,
  right: ParsedNaverItem,
  center: SearchCenter,
): number {
  const distanceDifference = distanceSquared(left, center) -
    distanceSquared(right, center);
  if (distanceDifference !== 0) return distanceDifference;
  return normalizeSearchText(left.name).localeCompare(normalizeSearchText(right.name));
}

function isStationQuery(query: string): boolean {
  return normalizeSearchText(query).endsWith("역");
}

function isRailStationCategory(category: string): boolean {
  const normalizedCategory = normalizeSearchText(category);
  return RAIL_STATION_CATEGORY_MARKERS.some((marker) =>
    normalizedCategory.includes(normalizeSearchText(marker))
  );
}

/** Map destination search is independent of registered-shop lookup. Legacy callers retain their contract. */
async function searchLocationCandidates(
  input: PlaceSearchInput,
  searchNaver: NaverSearch,
  geocodeNaver: NaverGeocode,
): Promise<PlaceSearchResult[]> {
  const queryKey = normalizeSearchText(input.query);
  // A one-character shop name is useful, but cannot identify a map destination.
  if (queryKey.length < 2) return [];
  if (queryKey === "서면") {
    return (await searchStation("서면역", input.center, searchNaver)).map((place) => ({ ...place, zoom: 15 }));
  }
  if (isStationQuery(input.query)) {
    return (await searchStation(input.query, input.center, searchNaver)).map((place) => ({ ...place, zoom: 15 }));
  }
  if (isAdministrativeRegionQuery(input.query) || isAddressQuery(input.query) || /(?:대로|로|길)$/.test(normalizeSearchText(input.query))) {
    // Provider failures must remain distinguishable from a successful empty result.
    const payload = await geocodeNaver(input.query, input.center);
    return parseNaverGeocodeResponse(payload, input.center, input.query, true)
      .map((place) => ({
        ...place,
        zoom: isAdministrativeRegionQuery(input.query) ? 11 : 15,
        ...(isUnqualifiedLocalRegion(place, input.query) ? { is_ambiguous_region: true } : {}),
      }));
  }

  const universityName = universityQueryName(queryKey);
  const providerQuery = universityName ?? (/^[가-힣0-9\s]+$/.test(input.query)
    ? input.query.replace(/\s+/g, "")
    : input.query);
  const payload = await searchNaver(providerQuery);
  const items = parseNaverItems(payload, input.center)
    .filter((item) => isMapDestination(item.category, queryKey) && matchesDestinationName(item.name, universityName ?? queryKey))
    .sort((left, right) =>
      destinationMatchRank(left.name, universityName ?? queryKey) - destinationMatchRank(right.name, universityName ?? queryKey) ||
      distanceMeters(left, input.center) - distanceMeters(right, input.center) ||
      left.name.localeCompare(right.name)
    );
  return items
    .filter((item, index, all) => all.slice(0, index).every((previous) =>
      normalizeSearchText(previous.name) !== normalizeSearchText(item.name) ||
      distanceMeters(previous, item) > STATION_DEDUPLICATION_DISTANCE_METERS
    ))
    .map((item) => ({ ...toMapLocation(item), zoom: 15 }))
    .slice(0, MAX_RESULTS);
}

function destinationMatchRank(name: string, queryKey: string): number {
  const nameKey = normalizeSearchText(name);
  if (nameKey === queryKey) return 0;
  return nameKey.startsWith(queryKey) ? 1 : 2;
}

function isUnqualifiedLocalRegion(place: PlaceSearchResult, query: string): boolean {
  const queryKey = normalizeSearchText(query);
  if (!/(?:읍|면|동|리)$/.test(queryKey)) return false;
  const regionName = place.address.trim().split(/\s+/).at(-1) ?? "";
  return normalizeSearchText(regionName) === queryKey;
}

function isMapDestination(category: string, queryKey: string): boolean {
  if (/(음식점|카페|술집|제과|베이커리)/.test(category)) return false;
  if (/(병원|의원|의료)/.test(category)) return /(?:병원|의원|의료원|보건소)$/.test(queryKey);
  if (/(학원|어학|교육센터)/.test(category)) return /(?:학원|어학원|교육센터)$/.test(queryKey);
  if (/(빌라|주거|아파트|건물|빌딩)/.test(category)) return /(?:빌라|아파트|빌딩|타워|센터)$/.test(queryKey);
  return /(시청|구청|군청|주민센터|행정기관|공공기관|법원|경찰서|소방서|학교|교통|철도|공원|관광|명소|시장|백화점|박물관|미술관|문화재|도서관|체육관|경기장|공연장)/.test(category);
}

function universityQueryName(queryKey: string): string | null {
  const aliases: Record<string, string> = {
    "홍대": "홍익대학교", "건대": "건국대학교", "숙대": "숙명여자대학교", "이대": "이화여자대학교",
  };
  if (aliases[queryKey]) return aliases[queryKey];
  return /^[가-힣]{2,}대$/.test(queryKey) ? `${queryKey}학교` : null;
}

function matchesDestinationName(name: string, queryKey: string): boolean {
  const nameKey = normalizeSearchText(name);
  if (nameKey === queryKey) return true;
  if (queryKey.endsWith("대학교")) {
    const remainder = nameKey.startsWith(queryKey) ? nameKey.slice(queryKey.length) : "";
    return /^[가-힣a-z]+캠퍼스$/.test(remainder);
  }
  // Bare fragments such as 리네 or 면작 must not expand into unrelated businesses or monuments.
  return /(?:시청|구청|군청|주민센터|공원|시장|백화점|박물관|미술관|병원|대학교|초등학교|중학교|고등학교)$/.test(queryKey) &&
    nameKey.startsWith(queryKey);
}

function matchesGeocodedAddress(address: string, query: string): boolean {
  const queryKey = normalizeSearchText(query);
  const parts = address.split(/\s+/);
  const shortParts = parts.map((part) => part.replace(/(?:특별자치시|특별자치도|특별시|광역시|시|군|구|읍|면|동|리)$/, ""));
  const provinceAliases: Record<string, string> = {
    "경기도": "경기", "강원특별자치도": "강원", "강원도": "강원",
    "충청북도": "충북", "충청남도": "충남", "전라북도": "전북", "전북특별자치도": "전북",
    "전라남도": "전남", "경상북도": "경북", "경상남도": "경남", "제주특별자치도": "제주",
  };
  shortParts[0] = provinceAliases[parts[0]] ?? shortParts[0];
  // Build only canonical suffix/alias variants; never discard unmatched input characters.
  let prefixes = new Set([""]);
  for (let index = 0; index < parts.length; index++) {
    const options = new Set([parts[index], shortParts[index]]);
    if (index === 0 && shortParts[0]) options.add(`${shortParts[0]}${/(?:도)$/.test(parts[0]) ? "도" : "시"}`);
    const nextPrefixes = new Set<string>();
    for (const prefix of prefixes) {
      for (const part of options) {
        let matched = prefix;
        for (const character of normalizeSearchText(part)) {
          matched += character;
          while (!queryKey.startsWith(matched)) matched = matched.slice(1);
          if (matched === queryKey) return true;
        }
        nextPrefixes.add(matched);
      }
    }
    prefixes = nextPrefixes;
  }
  return false;
}

function normalizeSearchText(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase().replace(/\s+/g, "");
}

function normalizeMatchText(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase().replace(/[^0-9a-z가-힣]/g, "");
}

function normalizeAddress(value: string): string {
  return normalizeMatchText(value)
    .replace(/^서울특별시/, "서울")
    .replace(/^부산광역시/, "부산")
    .replace(/^대구광역시/, "대구")
    .replace(/^인천광역시/, "인천")
    .replace(/^광주광역시/, "광주")
    .replace(/^대전광역시/, "대전")
    .replace(/^울산광역시/, "울산")
    .replace(/^세종특별자치시/, "세종")
    .replace(/^제주특별자치도/, "제주");
}

function distanceMeters(
  left: { lat: number; lng: number },
  right: { lat: number; lng: number },
): number {
  const earthRadiusMeters = 6_371_000;
  const latitudeDelta = degreesToRadians(right.lat - left.lat);
  const longitudeDelta = degreesToRadians(right.lng - left.lng);
  const leftLatitude = degreesToRadians(left.lat);
  const rightLatitude = degreesToRadians(right.lat);
  const haversine = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(leftLatitude) * Math.cos(rightLatitude) *
      Math.sin(longitudeDelta / 2) ** 2;
  return 2 * earthRadiusMeters * Math.asin(Math.min(1, Math.sqrt(haversine)));
}

function degreesToRadians(value: number): number {
  return value * Math.PI / 180;
}

function distanceSquared(
  place: { lat: number; lng: number },
  center: SearchCenter,
): number {
  const lat = place.lat - center.lat;
  const lng = place.lng - center.lng;
  return lat * lat + lng * lng;
}

function isCoordinate(
  value: unknown,
  minimum: number,
  maximum: number,
): value is number {
  return typeof value === "number" && Number.isFinite(value) &&
    value >= minimum && value <= maximum;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
