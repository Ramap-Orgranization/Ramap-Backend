export type ExistingExternalVenue = {
  address: string | null;
  naver_map_url: string | null;
  kakao_map_url: string | null;
};

export function requiresExistingVenueSelection(
  candidates: ExistingExternalVenue[],
  address: string | null,
  naverMapUrl: string | null,
  kakaoMapUrl: string | null,
): boolean {
  if (candidates.length === 0) return false;
  const hasIdentity = Boolean(address || naverMapUrl || kakaoMapUrl);
  if (!hasIdentity) return candidates.length > 0;
  return candidates.some((candidate) =>
    (address && candidate.address && normalizeVenueAddress(address) === normalizeVenueAddress(candidate.address)) ||
    (naverMapUrl && candidate.naver_map_url === naverMapUrl) ||
    (kakaoMapUrl && candidate.kakao_map_url === kakaoMapUrl)
  );
}

export function normalizeVenueAddress(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLowerCase();
}
