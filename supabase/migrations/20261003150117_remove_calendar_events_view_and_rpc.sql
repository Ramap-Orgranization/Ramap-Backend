BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- The calendar feature has been removed from the current app. Remove its
-- RPC first because its SQL body references the view without a catalog dependency.
DROP FUNCTION IF EXISTS public.fetch_calendar_event_page(date) RESTRICT;
DROP VIEW IF EXISTS public.calendar_events RESTRICT;

COMMIT;
