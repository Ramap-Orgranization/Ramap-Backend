-- Seed a photo-only review before applying the new write policy.
insert into auth.users(id) values ('00000000-0000-0000-0000-000000000001');
insert into public.ramen_shops(id, name) values ('00000000-0000-0000-0000-000000000002', '본문 필수 테스트');
insert into storage.objects(bucket_id, name, owner) values
    ('shop-review-images', '00000000-0000-0000-0000-000000000001/existing.jpg', '00000000-0000-0000-0000-000000000001'),
    ('shop-review-images', '00000000-0000-0000-0000-000000000001/new.jpg', '00000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
select set_config('request.jwt.claim.role', 'authenticated', false);
select public.submit_shop_review(
    '00000000-0000-0000-0000-000000000002', '',
    array['00000000-0000-0000-0000-000000000001/existing.jpg'], false
);
