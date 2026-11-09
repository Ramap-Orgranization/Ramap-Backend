# Verified notification publications

This API prepares explicit administrator-reviewed publications. Approved canonical `full_close`, `early_close`, and `planned_close` registrations also support automatic publication through the private operating-notice queue. Event-only pre-day/day-of reminders retain their meaning. New notification categories do not create new registration types.

## Authentication and transport

POST `admin-notification-publication` with the existing administrator Bearer token (same verified-user/admin-email policy as register-event). Gateway JWT validation remains enabled. Never put credentials in examples or source control.

POST `dispatch-notification-publications` requires `x-notification-dispatch-secret` matching `NOTIFICATION_DISPATCH_SECRET`. It additionally requires BOTH `NOTIFICATION_PUBLICATION_TRANSPORT_ENABLED=true` and the service-only database transport setting. Both default OFF. Missing configuration fails closed.

`schedule_notification_publications` installs a minute cron job. It reads the endpoint and matching dispatch secret from Vault entries `notification_publication_url` and `notification_dispatch_secret`; it makes no request while DB transport is OFF or configuration is missing. Activation is a separate operator action.

## Automatic operating-notice registration

With `notification_private.settings.operating_notice_automatic_enabled=true`, new canonical notices enter a durable queue in the same transaction as registration. Existing notices are not backfilled. Explicit publications reserve `announcement_id` during insertion and retain their own preview/publish workflow.

The dispatcher validates canonical public copy and payload size, then atomically rechecks the same notice, links it, and publishes once. `full_close`, `early_close`, and `planned_close` map to `temporary_closure`, `early_closing`, and `shortened_hours`. Current subscriber consent, category activation, visible shops, and supported device protocols still determine delivery. The preserved shop description, raw OCR, and internal review notes are never copied into automatic push text. The payload formatter uses only the confirmed shop name, dates, notice type, and closing time, with a type-specific title and a Korean sentence. It uses absolute Korean dates rather than an ambiguous “today”. This formatter is deterministic; it does not call an AI service.

Partial-day wording, last-order or waitlist details, exceptions, planned/changed/cancelled wording, and names whose Korean particle cannot be determined stop automatic publication with `operating_notice_copy_review_required`. Review the source and create an explicit sentence publication instead of removing the guard. The queue records the failure and bounded attempts; no push is sent. Expired, released, hidden, already linked, or unsupported legacy schedules are skipped. Validation failures remain recorded in the queue and retry at most five times; inspect `last_error` rather than changing canonical text automatically. Editing or deleting an automatically published notice invalidates pending old copy without generating a correction notification. Explicit correction/cancellation still uses the reviewed workflow below. Retries never reset uncertain provider outcomes.

The dispatcher claims at most 100 rows, obtains provider credentials before `prepare_notification_delivery`, and then rechecks consent, catalog activation, shop visibility, device ownership and supported protocol immediately before sending. Expired claimed work can be reclaimed; sending work, timeouts, lost provider acknowledgements, and failed completion acknowledgements become unknown and are never automatically resent. Operators must investigate unknown outcomes, not reset them to pending.

## Command envelope

All commands have `command`, `expected_revision`, and a unique `idempotency_key` (1–128 letters/digits/underscore/hyphen). Initial draft omits `announcement_id` (or sends null) and uses revision 0. Use the returned ID/revision thereafter. Reusing an idempotency key must represent the same action; stale revisions require rereading/reviewing, never blind retry.

Example initial request, using illustrative UUIDs only:

```json
{
  "command": "draft", "expected_revision": 0, "idempotency_key": "source-20261112-draft-1",
  "document": {
    "source": { "url": "https://www.instagram.com/p/EXAMPLE/", "raw_text": "Original official source, preserved separately", "official_verified": true },
    "facts": [{
      "id": "00000000-0000-4000-8000-000000000001",
      "shop_id": "00000000-0000-4000-8000-000000000002", "shop_name": "Verified branch",
      "type_id": "temporary_closure", "verified": true, "certainty": "confirmed",
      "starts_on": "2026-11-12", "ends_on": "2026-11-12", "starts_at": null, "ends_at": null,
      "time_meaning": "full_day", "exception_dates": [], "message": "11월 12일 임시휴무",
      "context_key": "branch-november-closures",
      "destination": { "version": 1, "action": "operating_notices" },
      "registration_type": "operating_notice", "registration_id": "00000000-0000-4000-8000-000000000003"
    }]
  }
}
```

For a reviewed complete sentence, set the fact's optional `message_format` to `"sentence"` and `notification_title` to the approved short title. `message` must itself include the correct shop, absolute dates, time meaning, certainty, and exceptions. Preview and publish use that exact sentence without bracketed metadata. Keep `source.raw_text` unchanged. Old facts without this opt-in retain their existing fragment format; automatic canonical notices use the safe formatter described above. Correction/cancellation wording remains explicitly reviewed, and title-only changes do not bypass the cancellation message check.

Facts preserve branch, dates/ranges, times, exceptions and certainty. `message` is reviewed atomic public copy, not raw source text. Unknown/unverified facts remain drafts and block publication. Never infer a clock time from “evening”. `last_order`, `closing`, `waitlist_end`, `opening`, `partial_day`, and `full_day` are distinct semantics.

1. Create draft and obtain announcement ID/revision.
2. Register canonical events/notices with optional `announcement_id` and `announcement_revision` in register-event. Event linkage exists before insertion webhook, and readiness is recorded only after participants are complete. Operating notices use the existing admin view, then link the base record. A partial registration error must be inspected before retrying; do not publish or blindly duplicate existing records.
3. Update draft with verified canonical registration IDs. A revision change requires explicitly revalidating/linking registrations against the new revision via service-only `link_notification_registration`. A prior revision's readiness is never inherited.
4. POST `preview` with ID/current revision/key. Preview reads persisted facts, checks every type combination and legacy/generic payload size, then records review. No delivery occurs.
5. POST `publish` with the same reviewed revision and a new action key. It revalidates payload and atomically publishes only ready verified facts. Concurrent/repeated requests are handled by database revision/idempotency checks.

`correct` accepts replacement document, preserving stable fact IDs for the corrected facts. Prior unsent deliveries are cancelled. `cancel` accepts the reviewed cancellation document and creates a cancellation draft for prior delivered/unknown history. Both require a new preview and explicit publish after canonical registration revalidation. Correction audience is prior delivered/unknown devices intersected with CURRENT consent; new fact identities do not inherit old delivery history. `admin-correct-registration` invalidates linked publication before editing canonical data, so update failure is safely unreviewed rather than leaving old content publishable.

## Split policy and privacy

One publication/revision/device produces at most one provider request. Incompatible contexts return `split_required`: create separate publications referencing the same official source, with distinct facts/registrations. Do not relabel context keys to bypass review. Already-published pipeline facts cannot be republished as new announcements; use the pipeline correction workflow. Already-sent standalone events cannot be imported into this pipeline, including through `correct`. They may still be corrected through the existing registration-correction workflow, but that does not create personalized correction outbox history or send a new pipeline correction. Pipeline correction/cancellation applies only to publications previously sent through this pipeline; no history import or backfill is supported. Multiple facts for the same canonical event are rejected.

Monthly full-day temporary closures of the same branch/month may enumerate exact separate dates, never merge gaps. A first-evening closure and subsequent full days require separate publications. Nov 12 lunch last-order/dinner closure and Nov 13 closure/collaboration require separate contexts/publications. Corrections replace date ranges instead of taking their union.

Recipient aggregation is OR, but content is only each device's currently selected fact intersection. Event facts include canonical host/participant subscribers; operating facts match their exact shop. Global event OFF removes event facts only. Raw source is never included. Protocol 0 receives only a single supported legacy event link/content; operating content is withheld. Protocol 1 uses `notification_id` (delivery UUID) and JSON `deep_link` version 1. Mixed destinations use `none`; external URLs must exactly match verified official public HTTPS source and pass strict URL validation. Only a user click opens external content.

## Local validation (fake provider only)

```sh
node --test supabase/functions/_shared/operating-notice-copy.test.mjs supabase/functions/_shared/notification*.test.mjs supabase/functions/_shared/operating-notice-publication.test.mjs supabase/functions/_shared/push-delivery.test.mjs supabase/functions/admin-notification-publication/handler.test.mjs supabase/functions/dispatch-notification-publications/handler.test.mjs supabase/functions/register-event/handler.test.mjs supabase/functions/notify-shop-event/handler.test.mjs supabase/functions/admin-correct-registration/handler.test.mjs
python3 supabase/tests/automatic_operating_notice_notifications_test.py
```

Run the independent isolated PostgreSQL publication runner separately with the deployed catalog baseline and the two new migrations. Do not apply unrelated dirty/untracked migrations. No real sending or deployment has been verified by these tests.

Delivered-fact deletion or changing its category is not an implicit correction. The database rejects preview/publish with `explicit_correction_required` unless the correction/cancellation explicitly represents each delivered stable fact ID under its original category. Keep the original category and write accurate cancellation/correction copy; do not move a fact to a new category to notify old-only subscribers. This check uses authoritative delivery history, not client-supplied history.

Cancellation requires an explicit replacement document with reviewed cancellation wording. Reusing the previous message unchanged is rejected with `explicit_cancellation_message_required`; do not merely change the command while retaining the original announcement copy.

Protocol 2 앱에는 단일 영업 공지 등록과 연결된 `operating_notices` 알림을 `{ "version": 2, "action": "operating_notices", "notice_id": "등록 공지 UUID" }`로 보낸다. Protocol 1, 여러 공지 묶음, 공지 등록이 없는 사실은 기존 목록 목적지를 유지한다. 입력 destination은 기존 version 1 계약을 유지하며, external_url 목적지는 변경하지 않는다.

적용 순서: `20261109010000_notification_notice_deep_link_protocol.sql`로 기기 등록의 protocol 2를 먼저 허용하고, payload 공유 모듈을 사용하는 발행/dispatcher 함수를 배포한 뒤 앱을 배포한다. 기존 protocol 0/1 기기는 계속 지원한다.
