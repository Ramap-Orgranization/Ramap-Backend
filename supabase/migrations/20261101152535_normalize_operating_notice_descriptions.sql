-- Released clients require a string description. Preserve the nullable source
-- while normalizing the public view used by direct reads, feeds and shop detail.
create or replace view public.shop_operating_notices with (security_invoker = true) as
select id, shop_id,
       case when notice_type = 'planned_close' then 'early_close' else notice_type end as notice_type,
       coalesce(description, '') as description, notice_date, start_time, end_time, source_url,
       created_at, updated_at, end_date, schedule_override, manually_released_at, daily_schedules,
       notice_type as notice_category
from operating_notice_private.shop_operating_notices
where notice_type = 'full_close' or (notice_type in ('early_close', 'planned_close') and end_time is not null);

notify pgrst, 'reload schema';
