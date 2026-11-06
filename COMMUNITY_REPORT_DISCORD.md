# 신고 Discord 알림

`20260929054849_notify_community_reports_discord.sql`은 새 `community_reports` 행을 비공개 outbox에 넣고, `pg_cron`이 매분 최대 20건을 Discord로 전송한다. 리뷰와 사용자 신고를 모두 포함한다. 앱의 신고 저장 흐름과 글 공개 상태는 바꾸지 않는다.

## 설정과 배포

1. 운영 Supabase Vault에서 **`community_reports_discord_webhook_url`** 이름의 secret을 만든다. 값에는 Discord 웹훅 주소를 입력한다. 주소를 SQL 파일, CLI 인자, 로그, 앱 설정에 기록하지 않는다.
2. 이 마이그레이션은 `ramap` 운영 DB에 적용되어 있다. 새 환경에 적용할 때는 `supabase migration list`로 이력을 확인한다. 마이그레이션은 `http` 확장을 `private` 스키마에 설치한다. 운영 프로젝트의 `supautils.privileged_extensions` 허용 목록에 `http`가 있어야 한다.
3. 아래 조회로 트리거, 예약 작업, 비공개 권한을 확인한다. 결과에 웹훅 주소나 outbox 전체 행을 출력하지 않는다.

```sql
select tgname from pg_trigger
where tgrelid = 'public.community_reports'::regclass
  and tgname = 'enqueue_community_report_discord';

select jobname, schedule, active from cron.job
where jobname = 'community-report-discord-dispatch';

select has_schema_privilege('anon', 'private', 'USAGE') as anon_private_usage,
       has_schema_privilege('authenticated', 'private', 'USAGE') as authenticated_private_usage,
       has_table_privilege('anon', 'private.community_report_discord_outbox', 'SELECT') as anon_outbox_select,
       has_table_privilege('authenticated', 'private.community_report_discord_outbox', 'SELECT') as authenticated_outbox_select;
```

실제 신고 한 건을 접수한 뒤, 운영자 권한에서 아래 조회로 전송 상태를 확인한다. `sent`이고 `http_status`가 2xx인지 확인하고 Discord 채널에서 같은 신고 ID를 찾는다.

```sql
select report_id, delivery_state, attempted_at, http_status
from private.community_report_discord_outbox
order by reported_at desc
limit 5;
```

## 전송 범위와 한계

Discord 메시지에는 신고 ID, 대상 종류와 ID, 정해진 사유 코드, 접수 시각, 접수 당시 `pending` 상태만 담는다. 신고자 ID, 신고 상세 설명, 리뷰 본문·사진, 프로필 내용은 보내지 않는다. Discord 멘션도 허용하지 않는다.

신고 INSERT는 HTTP 응답을 기다리지 않는다. Vault 설정이 없으면 대기 건은 큐에 남는다. 전송 실패나 2xx 이외의 응답은 `failed`로 기록하며 자동 재시도하지 않는다. 네트워크 성공 직후 DB 트랜잭션이 실패하는 드문 경우에는 다음 실행에서 같은 알림을 다시 보낼 수 있다. 이미 접수된 동일 대기 신고는 새 행이 생성되지 않으므로 새 알림도 발생하지 않는다. 이 마이그레이션은 기존 신고를 소급 전송하지 않는다.

`pg_net`의 요청 대기열에는 URL이 평문으로 저장되고, 현재 프로젝트에서는 일반 DB 역할에 그 테이블의 조회 권한이 있다. 이 알림은 `pg_net`을 사용하지 않으며, 웹훅 주소는 Vault에서 예약 작업이 실행될 때만 읽는다.
