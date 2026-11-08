begin;

set local lock_timeout = '5s';

-- Keep the API names used by the supported app builds.
drop function if exists public.fetch_shop_detail(uuid);
drop function if exists public.fetch_shop_detail_v2(uuid);
drop function if exists public.fetch_blocked_community_profiles();
drop function if exists public.fetch_filtered_review_feed_page(text, text, integer, timestamptz, uuid);
drop function if exists public.update_my_profile_visibility(boolean);

-- Apply after the media gateway and its callers have switched to the v2 routes.
drop function if exists public.resolve_media_locations(jsonb);
drop function if exists public.prepare_media_upload(text, text, text, bigint);
drop function if exists public.prepare_service_media(text, text, text, bigint);
drop function if exists public.complete_media_upload(uuid, text, text, text, bigint, text, text);
drop function if exists public.media_inventory(text, integer);
drop function if exists public.record_media_copy(text, text, text, text, text, text, bigint, timestamptz);

-- The current SECURITY DEFINER entry points still use these implementations.
revoke execute on function
    public.submit_shop_review(uuid, text, text[], boolean),
    public.update_shop_review(uuid, text, text[], boolean),
    public.delete_shop_review(uuid),
    public.fetch_profile_reviews_page_v2(uuid, bigint),
    public.fetch_profile_reviews_page_v3(uuid, bigint)
from public, anon, authenticated, service_role;

notify pgrst, 'reload schema';

commit;
