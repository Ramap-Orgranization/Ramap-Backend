begin;
-- Production default privileges can grant these roles directly, independently of PUBLIC.
revoke all on all functions in schema media_private from public,anon,authenticated;
revoke all on function public.prepare_media_upload(text,text,text,bigint),public.fetch_media_upload(uuid),public.delete_media_object(text,text) from public,anon;
grant execute on function public.prepare_media_upload(text,text,text,bigint),public.fetch_media_upload(uuid),public.delete_media_object(text,text) to authenticated;
commit;
