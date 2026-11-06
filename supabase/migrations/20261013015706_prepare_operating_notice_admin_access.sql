create view public.admin_shop_operating_notice_records with (security_invoker = true) as
select id, shop_id, raw_post_id, notice_type, description, notice_date, start_time, end_time, source_url, ocr_text, confidence, review_note, created_at, updated_at, end_date, schedule_override, manually_released_at, daily_schedules from public.shop_operating_notices;
revoke all on public.admin_shop_operating_notice_records from public, anon, authenticated;
grant select, insert, update, delete on public.admin_shop_operating_notice_records to service_role;
comment on view public.admin_shop_operating_notice_records is 'Service-only operating notice maintenance, including OCR and review metadata.';
notify pgrst, 'reload schema';
