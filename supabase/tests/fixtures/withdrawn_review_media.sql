-- The full review projection migration is tested separately. This media fixture
-- supplies its deterministic account review path mapping and one verified source.
create function media_private.account_review_photos_to_preserve(p_user_id uuid)
returns table(review_id uuid, photo_order bigint, source_path text, destination_path text)
language sql stable set search_path = ''
as $$
    select r.id, photo.ordinality, photo.path, 'withdrawn/' || r.id::text || '/' || photo.ordinality || '.jpg'
    from public.shop_reviews r cross join lateral unnest(r.image_paths) with ordinality photo(path, ordinality)
    where r.user_id = p_user_id;
$$;

insert into auth.users values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
insert into public.account_deletion_requests values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
insert into public.shop_reviews(id,user_id,image_paths) values (
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    array['dddddddd-dddd-4ddd-8ddd-dddddddddddd/photo.jpg']
);
insert into media_private.objects(bucket,path,owner_id,state,byte_size,content_type,checksum)
values ('shop-review-images','dddddddd-dddd-4ddd-8ddd-dddddddddddd/photo.jpg',
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd','ready',100,'image/jpeg',repeat('a',64));
insert into media_private.locations(media_id,provider,bucket,path,verified,etag)
select id,'r2','private',bucket || '/' || path,true,'source'
from media_private.objects where path='dddddddd-dddd-4ddd-8ddd-dddddddddddd/photo.jpg';
update media_private.settings set r2_read_enabled = true, r2_write_enabled = true, legacy_required = true;
