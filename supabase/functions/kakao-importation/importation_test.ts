import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { ImportationError, matchPlaces, parseImportedPlaces, parseKakaoBookmarks, parseKakaoFolderId, parseNaverBookmarks, parseNaverShareId, parseProviderUrl } from "./importation.ts"

Deno.test("Kakao short destination folder URL extracts folder ID", () => {
  const url = parseProviderUrl("https://map.kakao.com/?map_type=TYPE_MAP&folderid=22341040&target=other&page=bookmark").url
  assertEquals(parseKakaoFolderId(url), "22341040")
})
Deno.test("Kakao redirect destination scheme extracts folder ID", () => {
  const url = parseProviderUrl("https://map.kakao.com/?kakaomapScheme=open%3Fpage%3Dbookmark%26folderid%3D22341040").url
  assertEquals(parseKakaoFolderId(url), "22341040")
})
Deno.test("Naver short destination folder URL extracts share ID", () => {
  const url = parseProviderUrl("https://map.naver.com/p/favorite/sharedPlace/folder/9ac8d10ac2a249caaece702e962fec51").url
  assertEquals(parseNaverShareId(url), "9ac8d10ac2a249caaece702e962fec51")
})
Deno.test("Naver redirect destination my place folder URL extracts share ID", () => {
  const url = parseProviderUrl("https://map.naver.com/v5/favorite/myPlace/folder/67fbcee24edd4c5994f3d611bc46fe98").url
  assertEquals(parseNaverShareId(url), "67fbcee24edd4c5994f3d611bc46fe98")
})
Deno.test("provider parsers only accept bookmark records", () => {
  assertEquals(parseKakaoBookmarks({ favorites: [{ type: "PLACE", key: "45", display1: "가게", display2: "서울시" }, { type: "ADDRESS", display1: "not a place" }] }).length, 1)
  assertEquals(parseNaverBookmarks({ bookmarkList: [{ type: "place", sid: "16", name: "가게", address: "서울시", px: 127, py: 37 }, { type: "place", sid: "hidden", name: "제외", available: false }] }).length, 1)
})
Deno.test("imported places keep only valid names and coordinates", () => {
  assertEquals(parseImportedPlaces([{ sourceId: "16", name: " 가게 ", address: "서울시", lat: 37, lng: 127 }, { name: "" }]), [{ sourceId: "16", name: "가게", address: "서울시", lat: 37, lng: 127 }])
})
Deno.test("unsupported hosts are rejected", () => {
  const error = assertThrows(() => parseProviderUrl("https://evil.example/folder"), ImportationError)
  assertEquals(error.code, "unsupported_url")
})
Deno.test("ambiguous matches are not imported while exact Kakao ID wins", () => {
  const shops = [{ id: "one", kakao_place_url: "https://place.map.kakao.com/45", name: "동일", address: "서울", lat: 37, lng: 127 }, { id: "two", name: "동일", address: "서울", lat: 37, lng: 127 }]
  assertEquals(matchPlaces([{ sourceId: "45", name: "동일" }, { name: "동일", address: "서울" }], shops).map((item) => item.shopId), ["one", null])
})
Deno.test("different names match by unique address", () => {
  const shops = [{ id: "one", name: "도마유즈라멘", address: "서울 종로구 북촌로2길 14", lat: 37, lng: 127 }]
  assertEquals(matchPlaces([{ name: "도마 유즈라멘 안국", address: "서울 종로구 북촌로2길 14" }], shops)[0].shopId, "one")
})
Deno.test("different names match by a unique coordinate within 50 meters", () => {
  const shops = [{ id: "one", name: "시시오", address: "서울 강남구 선릉로89길 7", lat: 37.0001, lng: 127 }]
  assertEquals(matchPlaces([{ name: "시시오 라멘", lat: 37, lng: 127 }], shops)[0].shopId, "one")
})
Deno.test("different names match the clearly nearest coordinate", () => {
  const shops = [{ id: "one", name: "가까운 가게", address: "서울", lat: 37.00001, lng: 127 }, { id: "two", name: "먼 가게", address: "서울", lat: 37.0003, lng: 127 }]
  assertEquals(matchPlaces([{ name: "다른 이름", lat: 37, lng: 127 }], shops)[0].shopId, "one")
})
Deno.test("coordinate matching rejects distant or ambiguous shops", () => {
  const distant = [{ id: "one", name: "먼 매장", address: "서울", lat: 37.001, lng: 127 }]
  const nearby = [{ id: "one", name: "가게1", address: "서울", lat: 37.0001, lng: 127 }, { id: "two", name: "가게2", address: "서울", lat: 37.0002, lng: 127 }]
  assertEquals(matchPlaces([{ name: "다른 이름", lat: 37, lng: 127 }], distant)[0].shopId, null)
  assertEquals(matchPlaces([{ name: "다른 이름", lat: 37, lng: 127 }], nearby)[0].shopId, null)
})
