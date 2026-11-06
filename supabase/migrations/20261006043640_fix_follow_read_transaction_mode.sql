begin;

-- require_live_user() locks the auth row; PostgREST must run these POST RPCs
-- in a read-write transaction even though their responses only contain reads.
alter function public.fetch_my_follow_connections(text, bigint) volatile;
alter function public.fetch_my_follow_counts() volatile;

notify pgrst, 'reload schema';

commit;
