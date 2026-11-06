export function normalizeMapUrl(value: unknown, provider: "naver" | "kakao") {
  if (typeof value !== "string") return null;
  try {
    const raw = value.trim();
    const authority = raw.match(/^https:\/\/([^/?#]+)/i)?.[1] ?? "";
    const url = new URL(raw);
    const hostname = url.hostname.toLowerCase();
    if (url.protocol !== "https:" || authority.includes("@") || /:\d+$/.test(authority) || url.username || url.password || url.port || url.hash) return null;
    if (provider === "naver" && hostname === "map.naver.com" && /^\/(?:p\/entry|v5\/entry)\/place\/\d+$/.test(url.pathname)) return url.toString();
    if (provider === "naver" && hostname === "naver.me" && /^[A-Za-z0-9]+$/.test(url.pathname.slice(1)) && !url.search) return url.toString();
    if (provider === "kakao" && hostname === "place.map.kakao.com" && /^\/\d+$/.test(url.pathname) && !url.search) return url.toString();
    if (provider === "kakao" && hostname === "map.kakao.com" && /^\/link\/map\/\d+$/.test(url.pathname) && !url.search) return url.toString();
  } catch { /* invalid input */ }
  return null;
}
