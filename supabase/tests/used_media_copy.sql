\set ON_ERROR_STOP on
begin;
create function pg_temp.check_true(value boolean,label text) returns void language plpgsql as $$begin
 if value is distinct from true then raise exception 'FAIL: %',label; end if; end$$;
select set_config('request.jwt.claim.role','service_role',false);
insert into public.shop_events(event_type,start_date,end_date,image_paths) values
 ('collab',current_date-10,current_date-1,array['ended.jpg','shared.jpg','cross-bucket.jpg']),
 ('collab',current_date,current_date+1,array['active.jpg','shared.jpg']),
 ('popup',current_date+5,current_date+6,array['future.jpg']),
 ('popup',current_date-1,(now() at time zone 'Asia/Seoul')::date,array['today.jpg']),
 ('store_renewal',current_date-interval '2 months',null,array['old-renewal.jpg']);
insert into storage.objects(bucket_id,name,metadata) values
 ('event-images','ended.jpg','{"size":100,"mimetype":"image/jpeg"}'),
 ('event-images','active.jpg','{"size":100,"mimetype":"image/jpeg"}'),
 ('event-images','unused.jpg','{"size":100,"mimetype":"image/jpeg"}');
select pg_temp.check_true(public.media_copy_eligibility('event-images','ended.jpg')='{"needed":false,"reason":"ended_event"}','종료된 이벤트 사진 제외');
select pg_temp.check_true((public.media_copy_eligibility('event-images','shared.jpg')->>'needed')::boolean,'현재 이벤트가 재사용하는 사진 유지');
select pg_temp.check_true((public.media_copy_eligibility('event-images','future.jpg')->>'needed')::boolean,'미래 이벤트 사진 유지');
select pg_temp.check_true((public.media_copy_eligibility('event-images','today.jpg')->>'needed')::boolean,'한국 날짜 기준 오늘 종료되는 이벤트 유지');
select pg_temp.check_true(not (public.media_copy_eligibility('event-images','old-renewal.jpg')->>'needed')::boolean,'기존 리뉴얼 종료 규칙 재사용');
select pg_temp.check_true(public.media_copy_eligibility('event-images','unused.jpg')->>'reason'='unreferenced','어떤 데이터도 참조하지 않는 사진 제외');
select pg_temp.check_true(public.reserve_media_copy_v2('event-images','ended.jpg','{}') is null,'직접 복사 RPC도 종료된 사진은 예약하지 않음');
insert into public.community_reports(review_image_paths_snapshot,profile_avatar_path_snapshot) values(array['removed-review.jpg'],'old-avatar.jpg');
insert into public.feedback_submissions(attachment_path) values('evidence.jpg');
select pg_temp.check_true(public.media_copy_eligibility('shop-review-images','removed-review.jpg')->>'reason'='retained_evidence','신고 리뷰 증거 유지');
select pg_temp.check_true(public.media_copy_eligibility('profile-avatars','old-avatar.jpg')->>'reason'='retained_evidence','신고 프로필 증거 유지');
select pg_temp.check_true(public.media_copy_eligibility('news-report-evidence','evidence.jpg')->>'reason'='retained_evidence','기존 제보 증거 유지');
insert into public.shop_menu_items(image_url,event_id) values('https://images.example.workers.dev/menu-images/current.jpg',null);
insert into public.shop_menu_items(image_url,event_id) select 'https://source.example/menu-images/expired-menu.jpg',id from public.shop_events where 'ended.jpg'=any(image_paths);
insert into public.shop_menu_items(image_url,event_id) values('https://images.example.workers.dev/event-images/cross-bucket.jpg',null);
select pg_temp.check_true((public.media_copy_eligibility('event-images','cross-bucket.jpg')->>'needed')::boolean,'현재 메뉴가 재사용하는 종료 이벤트 사진 유지');
select pg_temp.check_true((public.media_copy_eligibility('menu-images','current.jpg')->>'needed')::boolean,'현재 메뉴가 사용하는 사진 유지');
select pg_temp.check_true(not (public.media_copy_eligibility('menu-images','expired-menu.jpg')->>'needed')::boolean,'종료된 이벤트 메뉴에서만 사용하는 사진 제외');
select pg_temp.check_true(exists(select 1 from jsonb_array_elements(public.media_inventory_v2()) i where i->>'path'='ended.jpg' and i->>'migration_needed'='false'),'inventory에 제외 사유를 유지');
select pg_temp.check_true(exists(select 1 from storage.objects where name='ended.jpg'),'제외 원본을 삭제하지 않음');
select pg_temp.check_true(not has_function_privilege('authenticated','public.media_copy_eligibility(text,text)','execute'),'운영용 참조 조사를 앱에 노출하지 않음');
rollback;
