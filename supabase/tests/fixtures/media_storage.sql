create role anon;
create role authenticated;
create role service_role;
-- Reproduce Supabase's direct default grants, not just PostgreSQL's PUBLIC grant.
alter default privileges grant execute on functions to anon,authenticated,service_role;
create schema auth;
create schema storage;
create schema community_private;
create schema account_profile_private;
create schema review_submission_private;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as $$select nullif(current_setting('request.jwt.claim.role',true),'')$$;
create table auth.users(id uuid primary key);
create table public.account_deletion_requests(user_id uuid primary key);
create table public.public_profiles(user_id uuid primary key,nickname text,bio text,avatar_path text,suspended_at timestamptz);
create table public.ramen_shops(id uuid primary key);
create table public.shop_reviews(id uuid primary key default gen_random_uuid(),shop_id uuid,user_id uuid,body text,image_paths text[],moderation_status text,is_public boolean);
create table public.community_reports(review_image_paths_snapshot text[],profile_avatar_path_snapshot text);
create table public.feedback_submissions(attachment_path text);
create table account_profile_private.profile_daily_change_counts(user_id uuid,change_date date,nickname_changes integer default 0,bio_changes integer default 0,primary key(user_id,change_date));
create table community_private.news_report_evidence_administrators(user_id uuid primary key);
create table storage.buckets(id text primary key,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid,owner_id text,metadata jsonb,created_at timestamptz default now(),updated_at timestamptz default now());
insert into storage.buckets values
('shop-review-images',false,5242880,array['image/jpeg','image/png']),
('profile-avatars',false,5242880,array['image/jpeg','image/png']),
('news-report-evidence',false,5242880,array['image/jpeg','image/png']),
('shop-profile-images',true,null,null),
('event-images',true,5242880,array['image/jpeg','image/png','image/webp']),
('menu-images',true,10485760,array['image/jpeg','image/png','image/webp']);

create function community_private.has_live_user() returns boolean language sql stable as $$
 select exists(select 1 from auth.users where id=auth.uid()) and not exists(select 1 from public.account_deletion_requests where user_id=auth.uid());
$$;
create function community_private.has_locked_live_user() returns boolean language sql as $$ select community_private.has_live_user() $$;
create function community_private.require_live_user() returns uuid language plpgsql as $$ begin
 if not community_private.has_live_user() then raise insufficient_privilege; end if; return auth.uid(); end $$;
create function community_private.require_current_member() returns uuid language sql as $$ select community_private.require_live_user() $$;
create function community_private.has_review_upload_permission() returns boolean language sql as $$ select community_private.has_live_user() $$;
create function public.fetch_public_community_profile(p_id uuid) returns jsonb language sql stable as $$
 select to_jsonb(p) from public.public_profiles p where user_id=p_id;
$$;
create function community_private.can_read_review_image(p_path text) returns boolean language sql stable as $$
 select (split_part(p_path,'/',1)=auth.uid()::text and community_private.has_live_user())
 or exists(select 1 from public.shop_reviews where p_path=any(image_paths) and is_public and moderation_status='published');
$$;
create function community_private.can_read_follow_header_avatar(p_path text) returns boolean language sql stable as $$ select false $$;
create function community_private.can_read_blocked_user_avatar(p_path text) returns boolean language sql stable as $$ select false $$;
create function community_private.can_delete_review_image(p_path text) returns boolean language sql as $$
 select split_part(p_path,'/',1)=auth.uid()::text
 and not exists(select 1 from public.shop_reviews where p_path=any(image_paths))
 and not exists(select 1 from public.community_reports where p_path=any(review_image_paths_snapshot));
$$;
create function community_private.can_delete_profile_avatar(p_path text) returns boolean language sql as $$
 select split_part(p_path,'/',1)=auth.uid()::text
 and not exists(select 1 from public.public_profiles where avatar_path=p_path)
 and not exists(select 1 from public.community_reports where profile_avatar_path_snapshot=p_path);
$$;
create function community_private.can_read_news_report_evidence(p_owner text) returns boolean language sql stable as $$
 select community_private.has_live_user() and (p_owner=auth.uid()::text or exists(select 1 from community_private.news_report_evidence_administrators where user_id=auth.uid()));
$$;
create function community_private.can_upload_news_report_evidence(p_owner text) returns boolean language sql stable as $$
 select p_owner=auth.uid()::text and community_private.has_live_user() and exists(select 1 from community_private.news_report_evidence_administrators where user_id=auth.uid());
$$;
create function community_private.can_delete_news_report_evidence(p_path text,p_owner text) returns boolean language sql stable as $$
 select community_private.can_read_news_report_evidence(p_owner) and not exists(select 1 from public.feedback_submissions where attachment_path=p_path);
$$;
create function public.shop_review_image_paths_belong_to_user(p_paths text[],p_owner uuid) returns boolean language sql as $$
 select not exists(select 1 from unnest(p_paths) p where split_part(p,'/',1)<>p_owner::text);
$$;
create function review_submission_private.reserve_submission(p_payload text) returns uuid language sql as $$ select null::uuid $$;
create function review_submission_private.remember_submission(p_payload text,p_id uuid) returns void language sql as $$ select $$;
create function account_profile_private.fetch_or_create_my_profile(p_id uuid) returns jsonb language sql as $$ select '{}'::jsonb $$;
create function account_profile_private.kst_profile_change_date(p_now timestamptz) returns date language sql as $$ select p_now::date $$;
create function public.begin_current_user_deletion() returns void language sql as $$
 insert into public.account_deletion_requests values(auth.uid()) on conflict do nothing;
$$;

-- Minimal domain references for used-photo migration tests.
alter table public.ramen_shops add column instagram_profile_image_path text;
create table public.external_venues(id uuid primary key default gen_random_uuid(),image_path text);
create table public.shop_events(id uuid primary key default gen_random_uuid(),event_type text,start_date date,end_date date,image_paths text[]);
create table public.shop_menu_items(image_url text,event_id uuid);
create table public.shop_menu_manual_overrides(image_url text,status text,action text);
create function public.event_is_active_on(event_type text,start_date date,end_date date,today date) returns boolean
language sql immutable set search_path='' as $$
 select case when event_type='store_renewal' then today<(start_date+interval '1 month')::date else end_date is null or end_date>=today end;
$$;
