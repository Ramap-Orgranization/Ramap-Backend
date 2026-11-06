-- New writes only support the two closure types. Keep legacy source rows for review.
alter table operating_notice_private.shop_operating_notices drop constraint shop_operating_notices_type_check;
alter table operating_notice_private.shop_operating_notices
    add constraint shop_operating_notices_type_check check (notice_type in ('full_close', 'early_close')) not valid;
alter table operating_notice_private.shop_operating_notices
    add constraint shop_operating_notices_supported_closure_check check (
        notice_type in ('full_close', 'early_close')
        and schedule_override is null and start_time is null and daily_schedules = '[]'::jsonb
        and ((notice_type = 'full_close' and end_time is null)
             or (notice_type = 'early_close' and end_time is not null))
    ) not valid;

-- Project only explicitly closed calendar dates into independent full_close rows.
-- Existing clients otherwise interpret a full_close calendar as a continuous monthly closure.
insert into operating_notice_private.shop_operating_notices
    (shop_id, raw_post_id, notice_type, description, notice_date, end_date,
     source_url, ocr_text, confidence, review_note)
select notice.shop_id, notice.raw_post_id, 'full_close', notice.description,
       (day.value->>'date')::date, (day.value->>'date')::date,
       notice.source_url, notice.ocr_text, notice.confidence, notice.review_note
from operating_notice_private.shop_operating_notices notice
cross join lateral jsonb_array_elements(notice.daily_schedules) day
where notice.notice_type = 'operating_notice' and day.value->'closed' = 'true'::jsonb
      and not exists (
          select 1 from operating_notice_private.shop_operating_notices existing
          where existing.shop_id = notice.shop_id and existing.source_url = notice.source_url
            and existing.notice_type = 'full_close' and existing.notice_date = (day.value->>'date')::date
            and existing.end_date = (day.value->>'date')::date
      )
on conflict do nothing;

insert into operating_notice_private.shop_operating_notices
    (shop_id, raw_post_id, notice_type, description, notice_date, end_date,
     source_url, ocr_text, confidence, review_note)
select notice.shop_id, notice.raw_post_id, 'full_close', notice.description,
       notice.notice_date, notice.end_date, notice.source_url, notice.ocr_text, notice.confidence, notice.review_note
from operating_notice_private.shop_operating_notices notice
where notice.notice_type = 'operating_notice' and notice.daily_schedules = '[]'::jsonb
      and notice.schedule_override->'closed' = 'true'::jsonb
      and not exists (
          select 1 from operating_notice_private.shop_operating_notices existing
          where existing.shop_id = notice.shop_id and existing.source_url = notice.source_url
            and existing.notice_type = 'full_close' and existing.notice_date = notice.notice_date
            and existing.end_date is not distinct from notice.end_date
      )
on conflict do nothing;

create or replace view public.shop_operating_notices with (security_invoker = true) as
select id, shop_id, notice_type, description, notice_date, start_time, end_time, source_url,
       created_at, updated_at, end_date, schedule_override, manually_released_at, daily_schedules
from operating_notice_private.shop_operating_notices
where notice_type = 'full_close' or (notice_type = 'early_close' and end_time is not null);

drop function if exists public.release_shop_operating_notice(uuid);
notify pgrst, 'reload schema';
