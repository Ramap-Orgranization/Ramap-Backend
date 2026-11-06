# Media API

배포·복사·복구는 [`infrastructure/r2-media/README.md`](../../infrastructure/r2-media/README.md)를 따른다.

- `/v2/resolve`: 최대 64개 논리 bucket/path를 기존 Supabase 권한으로 검사하고 R2 또는 Supabase 서명 주소를 반환한다. Supabase는 버킷별로 배치 서명하며 거절·누락된 경로는 null로 유지한다.
- `/v2/prepare`, `/v2/finalize`, `/v2/delete`: Supabase 세션으로 준비·실제 파일 검증·호환 복사·확정을 분리한다.
- `/v1/*`: 기존 클라이언트에는 Supabase 주소와 업로드 경로만 제공한다.
- `/v2/account/cleanup`: 계정 삭제 fence 이후 해당 계정의 작업만 claim하고 모든 관리 복사본 정리를 확인한다. 전역 큐는 정기 worker가 처리한다.
- `/internal/v2/*`: 신뢰된 서버 키를 가진 운영 도구 전용이다. 임의 URL을 서명하지 않는다.

R2 signed PUT은 비공개 pending 경로, MIME, Content-Length, create-once 조건에 결속한다. 확정 시 실제 파일 signature·크기·SHA-256을 확인한다. prepare 때 고정한 Supabase 호환 복사까지 검증한 뒤 ready로 전환한다. 만료된 업로드와 실패한 삭제는 30분 작업이 회수한다. 미지원 provider를 다른 저장소로 처리하지 않으며 실패로 남긴다.

공개 사진 Worker는 공개 버킷만 읽는다. `R2_PUBLIC_DELIVERY=worker`에서는 공유 캐시 없이 R2를 읽으므로 zone purge 토큰 없이 물리 삭제를 확정한다. 비공개 사진은 이 Worker에 연결하지 않는다.

새 외부 사진의 업로드·열람은 R2 전용이다. 이전 GCS 복사본은 삭제 전용 경로로만 정리한다. 필요한 설정·권한과 보존 조건은 배포 문서를 따른다.

파일·토큰·서명 주소·서버 키를 로그에 기록하지 않는다. 제품 권한은 Supabase RPC가 소유한다.
