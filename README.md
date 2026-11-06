# Ramap Backend

라멥의 Supabase 마이그레이션·Edge Functions, 서버 서비스와 배포 설정을 관리합니다. 앱 코드는 [Ramap-KMP](https://github.com/Ramap-Orgranization/Ramap-KMP)에 있습니다.

| 경로 | 역할 |
| --- | --- |
| `supabase/` | DB 마이그레이션, Edge Functions, 회귀 테스트와 [영업 상태 워커](supabase/workers/naver-operating-status/README.md) |
| `services/media-api/` | [사진 API와 정리 작업](services/media-api/README.md) |
| `services/public-media-worker/` | 공개 사진 전송과 CDN 캐시 |
| `infrastructure/r2-media/` | [Cloud Run·Cloudflare R2 배포와 운영 절차](infrastructure/r2-media/README.md) |
| `COMMUNITY_REPORT_DISCORD.md` | [신고 알림 운영 절차](COMMUNITY_REPORT_DISCORD.md) |

최초 이관은 Ramap-KMP의 `develop` 커밋 `9573300920cb79bb9f09262d09d0542246ff6a89`를 기준으로 했습니다. 기존 운영 Supabase 프로젝트, Cloud Run 서비스, Cloudflare Worker와 R2를 사용합니다. 마이그레이션을 적용하기 전에 대상 프로젝트와 적용 이력을 확인하세요. 현재 마이그레이션만으로 빈 DB를 재현할 수 있다고 가정하지 마세요.

## 로컬 검증

Node.js 22 이상, Python 3, Deno를 사용합니다. DB 픽스처 테스트에는 로컬 PostgreSQL의 `initdb`, `pg_ctl`, `psql`이 필요합니다. 운영 연동용 스크립트는 별도의 검증 환경을 확인한 뒤 실행하세요.

```sh
for package_dir in services/media-api services/public-media-worker supabase/workers/naver-operating-status; do
  npm --prefix "$package_dir" ci && npm --prefix "$package_dir" test || exit 1
done
npm --prefix services/public-media-worker run check
node --test $(find supabase/functions supabase/tests -name '*.test.mjs' -o -name '*_test.mjs')
deno test --allow-read=supabase/functions supabase/functions/_shared/media-storage.test.ts \
  supabase/functions/kakao-importation/importation_test.ts supabase/tests/shops_schema_test.ts
python3 -m unittest discover -s infrastructure/r2-media -p 'test_*.py'
python3 supabase/tests/my_review_count_test.py
python3 infrastructure/r2-media/deploy.py
```

## Supabase 연결

CLI 작업은 이 저장소 루트에서 실행합니다. 운영 도구에서 연결이 필요한 경우 승인된 프로젝트의 ref를 확인하고 `supabase link --project-ref <project-ref>`로 로컬 체크아웃을 연결합니다. 연결 후 `supabase migration list --linked`로 마이그레이션 이력을 조회할 수 있습니다.

운영 데이터 덤프와 비밀값은 Git 외부에 보관합니다. Edge Functions는 기존 프로젝트의 서버 비밀 설정을, Cloud Run은 기존 Secret Manager 설정을 사용합니다. 로컬 배포 연결 JSON은 체크아웃 밖의 절대 경로로 전달합니다.
