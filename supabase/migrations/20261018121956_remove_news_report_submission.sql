begin;

-- The app no longer accepts new event/new-menu/renewal reports. Keep existing
-- submissions and their evidence for the current review and retention flow.
drop function if exists public.submit_news_report(text, text);

notify pgrst, 'reload schema';
commit;
