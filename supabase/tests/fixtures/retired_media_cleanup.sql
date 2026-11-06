-- Model data already affected by the old retirement migration.
insert into auth.users values('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222');
insert into public.account_deletion_requests(user_id) values('11111111-1111-4111-8111-111111111111');
insert into media_private.objects(id,bucket,path,owner_id,state,byte_size,content_type) values
 ('10000000-0000-4000-8000-000000000001','profile-avatars','11111111-1111-4111-8111-111111111111/deleted.jpg','11111111-1111-4111-8111-111111111111','deleted',100,'image/jpeg'),
 ('10000000-0000-4000-8000-000000000002','profile-avatars','22222222-2222-4222-8222-222222222222/current.jpg','22222222-2222-4222-8222-222222222222','ready',100,'image/jpeg'),
 ('10000000-0000-4000-8000-000000000003','profile-avatars','33333333-3333-4333-8333-333333333333/orphan.jpg','33333333-3333-4333-8333-333333333333','ready',100,'image/jpeg');
insert into media_private.locations(media_id,provider,bucket,path,generation,verified,deleted)
 select id,'gcs','old-private',bucket||'/'||path,'123',true,true from media_private.objects
 where id in ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000003');
