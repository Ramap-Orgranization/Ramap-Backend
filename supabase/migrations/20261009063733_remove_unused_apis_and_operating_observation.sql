-- The operating-status worker must be deployed without the observation RPC
-- before this migration is applied. RESTRICT preserves dependent objects.
DROP FUNCTION IF EXISTS public.record_shop_operating_observation(text, text, text, text, integer, timestamp with time zone) RESTRICT;
DROP FUNCTION IF EXISTS public.delete_my_review(uuid) RESTRICT;
DROP FUNCTION IF EXISTS public.update_my_review(uuid, text, text[], boolean) RESTRICT;
DROP FUNCTION IF EXISTS public.event_overlaps_period(text, date, date, date, date) RESTRICT;
DROP FUNCTION IF EXISTS public.fetch_blocked_community_profile(uuid) RESTRICT;
DROP FUNCTION IF EXISTS public.is_community_profile_private(uuid) RESTRICT;

NOTIFY pgrst, 'reload schema';
