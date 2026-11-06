# Naver 영업 상태 Playwright 워커

Cloud Run에서 Chromium을 실행해 `ramen_shops.naver_place_url`의 네이버 지도 영업 상태를 읽고 `shop_operating_status`에 저장합니다.

## 로컬 실행

```bash
npm install
npm test

SUPABASE_URL="https://<project-ref>.supabase.co" \
SUPABASE_SERVICE_ROLE_KEY="<service-role-key>" \
WORKER_TOKEN="<random-token>" \
npm start
```

```bash
curl -X POST http://localhost:8080/run \
  -H "Authorization: Bearer <random-token>" \
  -H "Content-Type: application/json" \
  -d '{"limit":50}'
```

`/run`은 토큰을 먼저 확인하며, 인증 실패는 `401`을 반환합니다. 요청 본문은 JSON 객체만 허용하고 잘못된 JSON·배열·원시값은 `400`, 64 KiB를 초과하는 본문은 `413`으로 거절합니다. 본문을 생략하거나 빈 객체를 보내면 기존 기본값인 최대 10개를 처리합니다. 거절한 요청은 DB 작업이나 브라우저 수집을 시작하지 않습니다.

## Cloud Run 배포

먼저 Cloud Run 서비스의 환경변수 또는 Secret Manager 연동으로 다음 값을 설정합니다.

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `WORKER_TOKEN`

```bash
gcloud run deploy ramap-naver-operating-status \
  --source supabase/workers/naver-operating-status \
  --region asia-northeast3 \
  --allow-unauthenticated \
  --set-env-vars SUPABASE_URL="https://<project-ref>.supabase.co" \
  --set-secrets WORKER_TOKEN=ramap-naver-worker-token:latest \
  --set-secrets SUPABASE_SERVICE_ROLE_KEY=ramap-supabase-service-role-key:latest
```

`--allow-unauthenticated`은 Supabase Cron이 호출할 수 있게 하기 위한 설정입니다. 실제 실행 요청은 `WORKER_TOKEN`으로 보호합니다. 서비스 키와 토큰은 명령행 대신 Secret Manager를 사용하세요.

## Supabase Cron 연결

migration 적용 후 Vault에 Cloud Run URL과 워커 토큰을 저장하고, SQL Editor에서 한 번만 실행합니다.

```sql
select vault.create_secret(
    'https://ramap-naver-operating-status-<hash>-<region>.a.run.app',
    'naver_operating_status_worker_url'
);

select vault.create_secret('<same-worker-token>', 'naver_operating_status_worker_token');

select cron.schedule(
    'naver-operating-status-dispatcher',
    '*/5 * * * *',
    $$
    select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'naver_operating_status_worker_url') || '/run',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'naver_operating_status_worker_token')
        ),
        body := '{"limit": 50}'::jsonb
    );
    $$
);
```

기존 Job을 갱신할 때는 먼저 `select cron.unschedule('naver-operating-status-hourly');`를 실행합니다. 이후 `naver-operating-status-dispatcher`를 등록합니다.

dispatcher는 5분마다 due 상태가 된 매장만 최대 50개 claim합니다. 주간 영업시간이 있는 매장은 오전 8시 사전 확인, 영업 시작 30분 전 확인, 영업 중 60분 간격으로 다음 확인 시점을 계산합니다. 휴무·영업 종료 매장도 완전히 제외하지 않고 다음 영업일 오전 8시에 다시 확인합니다. 네이버 접근 실패는 15분, 30분, 60분으로 재시도 간격을 늘립니다.

네이버가 CAPTCHA나 접근 제한을 반환하면 우회하지 않고 해당 매장을 실패로 기록합니다.
