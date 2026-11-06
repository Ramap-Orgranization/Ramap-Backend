-- A previously verified file with a supported original, prepared only in the isolated DB.
insert into storage.objects(bucket_id,name,metadata) values('event-images','retired-source.jpg','{"size":100,"mimetype":"image/jpeg"}');
insert into media_private.objects(id,bucket,path,state,byte_size,content_type,checksum)
 values('dddddddd-dddd-4ddd-8ddd-dddddddddddd','event-images','retired-source.jpg','ready',100,'image/jpeg',repeat('a',64));
insert into media_private.locations(media_id,provider,bucket,path,generation,verified) values
 ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','gcs','old-public','event-images/retired-source.jpg','1',true),
 ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','supabase','event-images','retired-source.jpg',null,true);
